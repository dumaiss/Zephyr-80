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
void handler_fs2_close(const IocFrame *, IocFrame *);
void handler_fs2_opendir(const IocFrame *, IocFrame *);
void handler_fs2_readdir(const IocFrame *, IocFrame *);
void handler_fs2_closedir(const IocFrame *, IocFrame *);
void handler_fs2_stat(const IocFrame *, IocFrame *);
void handler_fs2_space(const IocFrame *, IocFrame *);

#endif
