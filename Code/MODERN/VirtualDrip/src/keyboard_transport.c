#define _DEFAULT_SOURCE

#include "keyboard_transport.h"

#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define VDP_BUSY_IDLE_TIMEOUT_MS 50

typedef struct {
    QueuedPacket entries[KEYBOARD_QUEUE_SIZE];
    size_t head;
    size_t tail;
    size_t count;
    uint64_t events_seen;
    uint64_t packets_queued;
    uint64_t packets_dropped;
    size_t high_water;
    pthread_mutex_t mutex;
    pthread_cond_t cond;
    bool shutting_down;
} KeyboardQueue;

typedef struct {
    TransportMode mode;
    pthread_mutex_t mutex;
    pthread_cond_t cond;
    uint64_t vdp_busy_enter_count;
    uint64_t frame_mark_count;
    uint64_t keyboard_held_count;
    uint64_t vdp_busy_timeout_count;
    struct timespec last_vdp_activity;
    bool has_vdp_activity;
    bool shutting_down;
} TransportGate;

struct KeyboardTransport {
    SerialPort *serial_port;
    pthread_t writer_thread;
    bool writer_started;
    KeyboardQueue queue;
    TransportGate gate;
    pthread_mutex_t stats_mutex;
    uint64_t keyboard_packets_sent;
    uint64_t keyboard_packets_failed;
    pthread_mutex_t diag_mutex;
    time_t last_diag_time;
    KeyboardTransportStats last_diag_stats;
};

static struct timespec timespec_add_ms(struct timespec value, long timeout_ms)
{
    value.tv_sec += timeout_ms / 1000;
    value.tv_nsec += (timeout_ms % 1000) * 1000000L;
    if (value.tv_nsec >= 1000000000L) {
        value.tv_sec += 1;
        value.tv_nsec -= 1000000000L;
    }
    return value;
}

static int timespec_compare(struct timespec left, struct timespec right)
{
    if (left.tv_sec != right.tv_sec) {
        return left.tv_sec < right.tv_sec ? -1 : 1;
    }
    if (left.tv_nsec != right.tv_nsec) {
        return left.tv_nsec < right.tv_nsec ? -1 : 1;
    }
    return 0;
}

static void keyboard_queue_init(KeyboardQueue *queue)
{
    memset(queue, 0, sizeof(*queue));
    pthread_mutex_init(&queue->mutex, NULL);
    pthread_cond_init(&queue->cond, NULL);
}

static void keyboard_queue_destroy(KeyboardQueue *queue)
{
    pthread_cond_destroy(&queue->cond);
    pthread_mutex_destroy(&queue->mutex);
}

static void keyboard_queue_shutdown(KeyboardQueue *queue)
{
    pthread_mutex_lock(&queue->mutex);
    queue->shutting_down = true;
    pthread_cond_broadcast(&queue->cond);
    pthread_mutex_unlock(&queue->mutex);
}

static bool keyboard_queue_push(KeyboardQueue *queue, const QueuedPacket *packet)
{
    bool queued = false;

    pthread_mutex_lock(&queue->mutex);
    if (queue->count >= KEYBOARD_QUEUE_SIZE) {
        queue->packets_dropped++;
        fprintf(stderr,
            "Keyboard queue full; dropped packet (drop=%llu qmax=%zu)\n",
            (unsigned long long)queue->packets_dropped,
            queue->high_water);
    } else {
        queue->entries[queue->head] = *packet;
        queue->head = (queue->head + 1) % KEYBOARD_QUEUE_SIZE;
        queue->count++;
        queue->packets_queued++;
        if (queue->count > queue->high_water) {
            queue->high_water = queue->count;
        }
        queued = true;
        pthread_cond_signal(&queue->cond);
    }
    pthread_mutex_unlock(&queue->mutex);

    return queued;
}

static bool keyboard_queue_wait_pop(KeyboardQueue *queue, QueuedPacket *packet)
{
    pthread_mutex_lock(&queue->mutex);
    while (queue->count == 0 && !queue->shutting_down) {
        pthread_cond_wait(&queue->cond, &queue->mutex);
    }

    if (queue->count == 0 && queue->shutting_down) {
        pthread_mutex_unlock(&queue->mutex);
        return false;
    }

    *packet = queue->entries[queue->tail];
    queue->tail = (queue->tail + 1) % KEYBOARD_QUEUE_SIZE;
    queue->count--;
    pthread_mutex_unlock(&queue->mutex);
    return true;
}

static void transport_gate_init(TransportGate *gate)
{
    memset(gate, 0, sizeof(*gate));
    gate->mode = TRANSPORT_INTERACTIVE;
    pthread_mutex_init(&gate->mutex, NULL);
    pthread_cond_init(&gate->cond, NULL);
}

static void transport_gate_destroy(TransportGate *gate)
{
    pthread_cond_destroy(&gate->cond);
    pthread_mutex_destroy(&gate->mutex);
}

static void transport_gate_shutdown(TransportGate *gate)
{
    pthread_mutex_lock(&gate->mutex);
    gate->shutting_down = true;
    pthread_cond_broadcast(&gate->cond);
    pthread_mutex_unlock(&gate->mutex);
}

static void transport_gate_enter_vdp_busy_locked(TransportGate *gate, struct timespec now)
{
    if (gate->mode != TRANSPORT_VDP_BUSY) {
        gate->vdp_busy_enter_count++;
    }
    gate->mode = TRANSPORT_VDP_BUSY;
    gate->last_vdp_activity = now;
    gate->has_vdp_activity = true;
}

static bool transport_gate_wait_until_interactive(TransportGate *gate)
{
    bool counted_hold = false;

    pthread_mutex_lock(&gate->mutex);
    while (gate->mode == TRANSPORT_VDP_BUSY && !gate->shutting_down) {
        if (!counted_hold) {
            gate->keyboard_held_count++;
            counted_hold = true;
        }

        struct timespec deadline = gate->has_vdp_activity
            ? timespec_add_ms(gate->last_vdp_activity, VDP_BUSY_IDLE_TIMEOUT_MS)
            : timespec_add_ms((struct timespec){ .tv_sec = time(NULL), .tv_nsec = 0 }, VDP_BUSY_IDLE_TIMEOUT_MS);

        int wait_status = pthread_cond_timedwait(&gate->cond, &gate->mutex, &deadline);
        if (wait_status == ETIMEDOUT && gate->mode == TRANSPORT_VDP_BUSY) {
            struct timespec now;
            clock_gettime(CLOCK_REALTIME, &now);
            struct timespec latest_deadline = gate->has_vdp_activity
                ? timespec_add_ms(gate->last_vdp_activity, VDP_BUSY_IDLE_TIMEOUT_MS)
                : deadline;
            if (!gate->has_vdp_activity || timespec_compare(now, latest_deadline) >= 0) {
                gate->mode = TRANSPORT_INTERACTIVE;
                gate->vdp_busy_timeout_count++;
                pthread_cond_broadcast(&gate->cond);
                break;
            }
        }
    }

    bool interactive = !gate->shutting_down;
    pthread_mutex_unlock(&gate->mutex);
    return interactive;
}

static void keyboard_transport_copy_stats(KeyboardTransport *transport, KeyboardTransportStats *stats)
{
    memset(stats, 0, sizeof(*stats));

    pthread_mutex_lock(&transport->queue.mutex);
    stats->keyboard_events_seen = transport->queue.events_seen;
    stats->keyboard_packets_queued = transport->queue.packets_queued;
    stats->keyboard_queue_dropped = transport->queue.packets_dropped;
    stats->keyboard_queue_high_water = transport->queue.high_water;
    pthread_mutex_unlock(&transport->queue.mutex);

    pthread_mutex_lock(&transport->stats_mutex);
    stats->keyboard_packets_sent = transport->keyboard_packets_sent;
    stats->keyboard_packets_failed = transport->keyboard_packets_failed;
    pthread_mutex_unlock(&transport->stats_mutex);

    pthread_mutex_lock(&transport->gate.mutex);
    stats->keyboard_held_due_to_vdp = transport->gate.keyboard_held_count;
    stats->vdp_busy_enter_count = transport->gate.vdp_busy_enter_count;
    stats->frame_mark_count = transport->gate.frame_mark_count;
    stats->vdp_busy_timeout_count = transport->gate.vdp_busy_timeout_count;
    stats->mode = transport->gate.mode;
    pthread_mutex_unlock(&transport->gate.mutex);
}

static bool keyboard_transport_stats_changed(const KeyboardTransportStats *left, const KeyboardTransportStats *right)
{
    return memcmp(left, right, sizeof(*left)) != 0;
}

static void keyboard_transport_log_stats(KeyboardTransport *transport, bool force)
{
    pthread_mutex_lock(&transport->diag_mutex);

    time_t now = time(NULL);
    if (!force && now == transport->last_diag_time) {
        pthread_mutex_unlock(&transport->diag_mutex);
        return;
    }

    KeyboardTransportStats stats;
    keyboard_transport_copy_stats(transport, &stats);
    if (!force && !keyboard_transport_stats_changed(&stats, &transport->last_diag_stats)) {
        transport->last_diag_time = now;
        pthread_mutex_unlock(&transport->diag_mutex);
        return;
    }

    printf("kbd: seen=%llu queued=%llu sent=%llu fail=%llu drop=%llu qmax=%zu held=%llu\n",
        (unsigned long long)stats.keyboard_events_seen,
        (unsigned long long)stats.keyboard_packets_queued,
        (unsigned long long)stats.keyboard_packets_sent,
        (unsigned long long)stats.keyboard_packets_failed,
        (unsigned long long)stats.keyboard_queue_dropped,
        stats.keyboard_queue_high_water,
        (unsigned long long)stats.keyboard_held_due_to_vdp);
    printf("gate: mode=%s vdp=%llu frame=%llu timeout=%llu\n",
        stats.mode == TRANSPORT_VDP_BUSY ? "VDP_BUSY" : "INTERACTIVE",
        (unsigned long long)stats.vdp_busy_enter_count,
        (unsigned long long)stats.frame_mark_count,
        (unsigned long long)stats.vdp_busy_timeout_count);

    transport->last_diag_time = now;
    transport->last_diag_stats = stats;
    pthread_mutex_unlock(&transport->diag_mutex);
}

static void keyboard_transport_maybe_log_stats(KeyboardTransport *transport)
{
    keyboard_transport_log_stats(transport, false);
}

static void *keyboard_writer_thread(void *context)
{
    KeyboardTransport *transport = (KeyboardTransport *)context;

    for (;;) {
        QueuedPacket packet;
        if (!keyboard_queue_wait_pop(&transport->queue, &packet)) {
            break;
        }

        if (!transport_gate_wait_until_interactive(&transport->gate)) {
            break;
        }

        bool sent = serial_port_send_packet(
            transport->serial_port,
            packet.type,
            packet.payload,
            packet.length);

        pthread_mutex_lock(&transport->stats_mutex);
        if (sent) {
            transport->keyboard_packets_sent++;
        } else {
            transport->keyboard_packets_failed++;
        }
        pthread_mutex_unlock(&transport->stats_mutex);

        if (!sent) {
            fprintf(stderr, "Keyboard packet send failed\n");
        }
        keyboard_transport_maybe_log_stats(transport);
    }

    return NULL;
}

KeyboardTransport *keyboard_transport_create(SerialPort *serial_port)
{
    KeyboardTransport *transport = calloc(1, sizeof(*transport));
    if (transport == NULL) {
        fprintf(stderr, "Failed to allocate keyboard transport\n");
        return NULL;
    }

    transport->serial_port = serial_port;
    keyboard_queue_init(&transport->queue);
    transport_gate_init(&transport->gate);
    pthread_mutex_init(&transport->stats_mutex, NULL);
    pthread_mutex_init(&transport->diag_mutex, NULL);
    return transport;
}

void keyboard_transport_destroy(KeyboardTransport *transport)
{
    if (transport == NULL) {
        return;
    }

    keyboard_transport_stop(transport);
    pthread_mutex_destroy(&transport->diag_mutex);
    pthread_mutex_destroy(&transport->stats_mutex);
    transport_gate_destroy(&transport->gate);
    keyboard_queue_destroy(&transport->queue);
    free(transport);
}

bool keyboard_transport_start(KeyboardTransport *transport)
{
    if (transport == NULL || transport->writer_started) {
        return true;
    }

    if (pthread_create(&transport->writer_thread, NULL, keyboard_writer_thread, transport) != 0) {
        perror("pthread_create");
        return false;
    }

    transport->writer_started = true;
    return true;
}

void keyboard_transport_stop(KeyboardTransport *transport)
{
    if (transport == NULL) {
        return;
    }

    keyboard_queue_shutdown(&transport->queue);
    transport_gate_shutdown(&transport->gate);
    if (transport->writer_started) {
        pthread_join(transport->writer_thread, NULL);
        transport->writer_started = false;
    }

    keyboard_transport_log_stats(transport, true);
}

bool keyboard_transport_enqueue(
    KeyboardTransport *transport,
    uint8_t type,
    const uint8_t *payload,
    uint8_t length)
{
    if (transport == NULL || length > MAX_PACKET_PAYLOAD) {
        return false;
    }

    QueuedPacket packet;
    packet.type = type;
    packet.length = length;
    if (length > 0 && payload != NULL) {
        memcpy(packet.payload, payload, length);
    }

    bool queued = keyboard_queue_push(&transport->queue, &packet);
    keyboard_transport_maybe_log_stats(transport);
    return queued;
}

void keyboard_transport_note_keyboard_event(KeyboardTransport *transport)
{
    if (transport == NULL) {
        return;
    }

    pthread_mutex_lock(&transport->queue.mutex);
    transport->queue.events_seen++;
    pthread_mutex_unlock(&transport->queue.mutex);
}

void keyboard_transport_note_incoming_packet(KeyboardTransport *transport, const Packet *packet)
{
    if (transport == NULL || packet == NULL) {
        return;
    }

    pthread_mutex_lock(&transport->gate.mutex);
    switch (packet->type) {
    case PACKET_VDP_CTRL_WRITE:
    case PACKET_VDP_DATA_WRITE: {
        struct timespec now;
        clock_gettime(CLOCK_REALTIME, &now);
        transport_gate_enter_vdp_busy_locked(&transport->gate, now);
        break;
    }
    case PACKET_FRAME_MARK:
        transport->gate.frame_mark_count++;
        if (transport->gate.mode == TRANSPORT_VDP_BUSY) {
            transport->gate.mode = TRANSPORT_INTERACTIVE;
            pthread_cond_broadcast(&transport->gate.cond);
        }
        break;
    case PACKET_RESET:
    case PACKET_PING:
    default:
        break;
    }
    pthread_mutex_unlock(&transport->gate.mutex);

    keyboard_transport_maybe_log_stats(transport);
}

void keyboard_transport_get_stats(KeyboardTransport *transport, KeyboardTransportStats *stats)
{
    if (transport == NULL || stats == NULL) {
        return;
    }

    keyboard_transport_copy_stats(transport, stats);
}
