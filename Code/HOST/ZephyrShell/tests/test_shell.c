#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "builtins.h"
#include "exec.h"
#include "mock_fs.h"
#include "parser.h"
#include "path.h"

static unsigned checks;

#define CHECK(condition) do { ++checks; if (!(condition)) { \
    fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #condition); \
    exit(1); } } while (0)

static void parse_tests(void)
{
    char line[160];
    char *argv[ZSH_MAX_ARGS];
    uint8_t argc;
    unsigned i;

    strcpy(line, ""); CHECK(zsh_parse_line(line, argv, &argc) == ZSH_PARSE_OK && argc == 0);
    strcpy(line, "  \t "); CHECK(zsh_parse_line(line, argv, &argc) == ZSH_PARSE_OK && argc == 0);
    strcpy(line, "cp one two"); CHECK(zsh_parse_line(line, argv, &argc) == ZSH_PARSE_OK && argc == 3);
    CHECK(strcmp(argv[1], "one") == 0 && strcmp(argv[2], "two") == 0);
    strcpy(line, "echo 'one two' x"); CHECK(zsh_parse_line(line, argv, &argc) == ZSH_PARSE_OK);
    CHECK(argc == 3 && strcmp(argv[1], "one two") == 0);
    strcpy(line, "echo \"one two\""); CHECK(zsh_parse_line(line, argv, &argc) == ZSH_PARSE_OK);
    CHECK(argc == 2 && strcmp(argv[1], "one two") == 0);
    strcpy(line, "a b c d e f g h i j k l m n o p");
    CHECK(zsh_parse_line(line, argv, &argc) == ZSH_PARSE_OK && argc == ZSH_MAX_ARGS);
    strcpy(line, "a b c d e f g h i j k l m n o p q");
    CHECK(zsh_parse_line(line, argv, &argc) == ZSH_PARSE_TOO_MANY_ARGS);
    for (i = 0; i < ZSH_LINE_SIZE; ++i) line[i] = 'x';
    line[ZSH_LINE_SIZE] = 0;
    CHECK(zsh_parse_line(line, argv, &argc) == ZSH_PARSE_TOO_LONG);
    strcpy(line, "echo 'broken");
    CHECK(zsh_parse_line(line, argv, &argc) == ZSH_PARSE_UNTERMINATED_QUOTE);
}

static void path_tests(void)
{
    char parent[ZSH_PATH_SIZE];
    char leaf[13];
    zsh_path_scope_t scope;

    CHECK(zsh_path_split("/", parent, sizeof(parent), leaf) == ZEP_FS_BAD_NAME);
    CHECK(zsh_path_split(".", parent, sizeof(parent), leaf) == ZEP_FS_OK &&
          strcmp(parent, ".") == 0 && strcmp(leaf, ".") == 0);
    CHECK(zsh_path_split("..", parent, sizeof(parent), leaf) == ZEP_FS_OK &&
          strcmp(parent, ".") == 0 && strcmp(leaf, "..") == 0);
    CHECK(zsh_path_split("FOO", parent, sizeof(parent), leaf) == ZEP_FS_OK &&
          strcmp(parent, ".") == 0 && strcmp(leaf, "FOO") == 0);
    CHECK(zsh_path_split("FOO/BAR", parent, sizeof(parent), leaf) == ZEP_FS_OK &&
          strcmp(parent, "FOO") == 0 && strcmp(leaf, "BAR") == 0);
    CHECK(zsh_path_split("/FOO/BAR", parent, sizeof(parent), leaf) == ZEP_FS_OK &&
          strcmp(parent, "/FOO") == 0 && strcmp(leaf, "BAR") == 0);
    CHECK(zsh_path_split("../FOO/BAR.TXT", parent, sizeof(parent), leaf) == ZEP_FS_OK &&
          strcmp(parent, "../FOO") == 0 && strcmp(leaf, "BAR.TXT") == 0);

    mock_fs_reset();
    mock_fs_add_dir("/GOOD");
    CHECK(zep_fs_chdir("/GOOD") == ZEP_FS_OK);
    CHECK(zsh_path_chdir_atomic("../MISSING/TAIL") == ZEP_FS_NOT_FOUND);
    CHECK(strcmp(mock_fs_cwd(), "/GOOD") == 0);
    CHECK(zsh_path_enter_parent("../MISSING/FILE", &scope) == ZEP_FS_NOT_FOUND);
    CHECK(strcmp(mock_fs_cwd(), "/GOOD") == 0);
    CHECK(zsh_path_chdir_atomic(".") == ZEP_FS_OK);
    CHECK(zsh_path_chdir_atomic("..") == ZEP_FS_OK && strcmp(mock_fs_cwd(), "/") == 0);
    CHECK(zsh_path_chdir_atomic("/") == ZEP_FS_OK);
}

static void exec_path_tests(void)
{
    char name[13];
    zep_fs_stat_t info;
    zep_fs_handle_t handle;

    mock_fs_reset();
    mock_fs_add_dir("/CPM"); mock_fs_add_dir("/CPM/A");
    mock_fs_add_dir("/WORK");
    mock_fs_add_file("/CPM/A/SDPUT.COM", 321, 7);
    CHECK(zep_fs_chdir("/WORK") == ZEP_FS_OK);
    CHECK(zsh_exec_open_path("/CPM/A/sdput", name, &info, &handle) ==
          ZEP_FS_OK);
    CHECK(strcmp(name, "SDPUT.COM") == 0 && info.size == 321);
    CHECK(strcmp(mock_fs_cwd(), "/WORK") == 0);
    CHECK(zep_fs_close(handle) == ZEP_FS_OK);
}

static void one_copy(uint32_t size)
{
    zep_fs_status_t status;
    mock_fs_reset();
    mock_fs_add_dir("/SRC"); mock_fs_add_dir("/DST");
    mock_fs_add_file("/SRC/FILE.BIN", size, 0x31);
    status = zsh_copy_file("/SRC/FILE.BIN", "/DST/COPY.BIN");
    CHECK(status == ZEP_FS_OK);
    CHECK(mock_fs_size("/DST/COPY.BIN") == size);
    if (size) {
        CHECK(mock_fs_byte("/DST/COPY.BIN", 0) == 0x31);
        CHECK(mock_fs_byte("/DST/COPY.BIN", size - 1) == (uint8_t)(0x31 + (uint8_t)(size - 1)));
    }
}

static void copy_tests(void)
{
    one_copy(0); one_copy(1); one_copy(511); one_copy(512); one_copy(513);
    one_copy(4097); one_copy(70000);

    mock_fs_reset(); mock_fs_add_dir("/SRC"); mock_fs_add_dir("/DST");
    mock_fs_add_file("/SRC/FILE.BIN", 513, 0x21);
    CHECK(zsh_copy_file("/SRC/FILE.BIN", "/DST") == ZEP_FS_OK);
    CHECK(mock_fs_size("/DST/FILE.BIN") == 513);

    mock_fs_reset(); mock_fs_add_dir("/SRC"); mock_fs_add_dir("/DST");
    mock_fs_add_file("/SRC/FILE.BIN", 17, 0x41);
    CHECK(zep_fs_chdir("/DST") == ZEP_FS_OK);
    CHECK(zsh_copy_file("/SRC/FILE.BIN", ".") == ZEP_FS_OK);
    CHECK(mock_fs_size("/DST/FILE.BIN") == 17);
    CHECK(strcmp(mock_fs_cwd(), "/DST") == 0);

    mock_fs_reset(); mock_fs_add_dir("/SRC");
    mock_fs_add_file("/SRC/FILE.BIN", 19, 0x51);
    CHECK(zsh_copy_file("/SRC/FILE.BIN", "/SRC") == ZEP_FS_EXISTS);
    CHECK(mock_fs_size("/SRC/FILE.BIN") == 19);

    mock_fs_reset(); mock_fs_add_dir("/SRC"); mock_fs_add_dir("/DST");
    mock_fs_add_file("/SRC/FILE.BIN", 1024, 1);
    mock_fs_fail_read(2, ZEP_FS_IO);
    CHECK(zsh_copy_file("/SRC/FILE.BIN", "/DST/COPY.BIN") == ZEP_FS_IO);
    CHECK(zsh_copy_file("/SRC/FILE.BIN", "/DST/AGAIN.BIN") == ZEP_FS_OK);

    mock_fs_reset(); mock_fs_add_dir("/SRC"); mock_fs_add_dir("/DST");
    mock_fs_add_file("/SRC/FILE.BIN", 1024, 1);
    mock_fs_fail_write(1, ZEP_FS_NO_SPACE);
    CHECK(zsh_copy_file("/SRC/FILE.BIN", "/DST/COPY.BIN") == ZEP_FS_NO_SPACE);
    CHECK(zsh_copy_file("/SRC/FILE.BIN", "/DST/AGAIN.BIN") == ZEP_FS_OK);

    mock_fs_reset(); mock_fs_add_dir("/SRC"); mock_fs_add_dir("/DST");
    mock_fs_add_file("/SRC/FILE.BIN", 1024, 1);
    mock_fs_fail_write(1, ZEP_FS_UNKNOWN_WRITE);
    CHECK(zsh_copy_file("/SRC/FILE.BIN", "/DST/COPY.BIN") == ZEP_FS_UNKNOWN_WRITE);
    CHECK(zsh_copy_file("/SRC/FILE.BIN", "/DST/AGAIN.BIN") == ZEP_FS_OK);
}

static void move_tests(void)
{
    mock_fs_reset(); mock_fs_add_dir("/A");
    mock_fs_add_file("/A/OLD.TXT", 12, 3);
    CHECK(zsh_move_file("/A/OLD.TXT", "/A/NEW.TXT") == ZEP_FS_OK);
    CHECK(!mock_fs_exists("/A/OLD.TXT") && mock_fs_exists("/A/NEW.TXT"));

    mock_fs_reset(); mock_fs_add_dir("/A"); mock_fs_add_dir("/B");
    mock_fs_add_file("/A/OLD.TXT", 900, 3);
    CHECK(zsh_move_file("/A/OLD.TXT", "/B/NEW.TXT") == ZEP_FS_OK);
    CHECK(!mock_fs_exists("/A/OLD.TXT") && mock_fs_exists("/B/NEW.TXT"));

    mock_fs_reset(); mock_fs_add_dir("/A"); mock_fs_add_dir("/B");
    mock_fs_add_file("/A/OLD.TXT", 33, 4);
    CHECK(zsh_move_file("/A/OLD.TXT", "/B") == ZEP_FS_OK);
    CHECK(!mock_fs_exists("/A/OLD.TXT") && mock_fs_exists("/B/OLD.TXT"));

    mock_fs_reset(); mock_fs_add_dir("/A"); mock_fs_add_dir("/B");
    mock_fs_add_file("/A/OLD.TXT", 900, 3);
    mock_fs_fail_write(1, ZEP_FS_IO);
    CHECK(zsh_move_file("/A/OLD.TXT", "/B/NEW.TXT") == ZEP_FS_IO);
    CHECK(mock_fs_exists("/A/OLD.TXT"));

    mock_fs_reset(); mock_fs_add_dir("/A"); mock_fs_add_dir("/B");
    mock_fs_add_file("/A/OLD.TXT", 900, 3);
    mock_fs_fail_write(1, ZEP_FS_UNKNOWN_WRITE);
    CHECK(zsh_move_file("/A/OLD.TXT", "/B/NEW.TXT") == ZEP_FS_UNKNOWN_WRITE);
    CHECK(mock_fs_exists("/A/OLD.TXT"));
}

static void iterator_tests(void)
{
    mock_fs_reset(); mock_fs_add_file("/ONE.TXT", 1, 1);
    CHECK(zsh_list_path(0, 0) == ZEP_FS_OK);
    CHECK(mock_fs_closedir_count() == 1);
    CHECK(zsh_list_path(0, 0) == ZEP_FS_OK);
    CHECK(mock_fs_closedir_count() == 2);

    mock_fs_reset(); mock_fs_add_file("/ONE.TXT", 1, 1);
    mock_fs_fail_readdir(2, ZEP_FS_IO);
    CHECK(zsh_list_path(0, 0) == ZEP_FS_IO);
    CHECK(mock_fs_closedir_count() == 1);
}

int main(void)
{
    parse_tests(); path_tests(); exec_path_tests(); copy_tests(); move_tests();
    iterator_tests();
    printf("ZephyrShell host tests: %u checks passed\n", checks);
    mock_fs_reset();
    return 0;
}
