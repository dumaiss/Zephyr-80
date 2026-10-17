#ifndef FS2_H
#define FS2_H

#include "ioc_frame.h"

void fs2_init(void);
void fs2_media_invalidated(void);

void handler_fs2_caps(const IocFrame *, IocFrame *);
void handler_fs2_generation(const IocFrame *, IocFrame *);
void handler_fs2_reset(const IocFrame *, IocFrame *);
void handler_fs2_root(const IocFrame *, IocFrame *);
void handler_fs2_push(const IocFrame *, IocFrame *);
void handler_fs2_open_ro(const IocFrame *, IocFrame *);
void handler_fs2_read(const IocFrame *, IocFrame *);
void handler_fs2_read_run(const IocFrame *, IocFrame *);
/* After a bulk phase: true while the admitted run has packets left. */
bool fs2_run_more(void);
/* Arm the admitted run's next packet.  Returns true when one is armed (the
 * caller runs it), false when no run is in progress. */
bool fs2_run_next(void);
/* Forget the run in progress (its packets ended or a phase failed). */
void fs2_run_end(void);
void handler_fs2_close(const IocFrame *, IocFrame *);
void handler_fs2_opendir(const IocFrame *, IocFrame *);
void handler_fs2_readdir(const IocFrame *, IocFrame *);
void handler_fs2_closedir(const IocFrame *, IocFrame *);
void handler_fs2_stat(const IocFrame *, IocFrame *);
void handler_fs2_space(const IocFrame *, IocFrame *);
void handler_fs2_open_rw(const IocFrame *, IocFrame *);
void handler_fs2_write(const IocFrame *, IocFrame *);
void handler_fs2_sync(const IocFrame *, IocFrame *);
void handler_fs2_truncate(const IocFrame *, IocFrame *);
void handler_fs2_unlink(const IocFrame *, IocFrame *);
void handler_fs2_rename(const IocFrame *, IocFrame *);
void handler_fs2_mkdir(const IocFrame *, IocFrame *);
void handler_fs2_rmdir(const IocFrame *, IocFrame *);

#endif
