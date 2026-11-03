// compat.c — bionic 缺的 glibc 扩展，给 opentui 的 zig 核心补上。
//
// 目前只需要一个：pthread_tryjoin_np（glibc 非阻塞 join）。
// bionic 没有它，dlopen 到那一步就报
//   cannot locate symbol "pthread_tryjoin_np" referenced by .../libopentui.so
//
// 语义：线程还没结束 → EBUSY；已经结束 → 正常 join。
#include <errno.h>
#include <pthread.h>
#include <signal.h>

int pthread_tryjoin_np(pthread_t thread, void **retval) {
  int rc = pthread_kill(thread, 0);
  if (rc == ESRCH) return pthread_join(thread, retval);  // 已退出，可以收尸
  if (rc != 0) return rc;
  return EBUSY;  // 还活着
}
