/*
 * Minimal STAILQ compatibility header for MinGW builds.
 *
 * libebur128 uses only the singly-linked tail queue macros below. Windows
 * toolchains do not provide the BSD <sys/queue.h> header that Unix hosts do.
 */
#ifndef PARSO_CEBUR128_COMPAT_SYS_QUEUE_H
#define PARSO_CEBUR128_COMPAT_SYS_QUEUE_H

#define STAILQ_HEAD(name, type) \
    struct name { \
        struct type *stqh_first; \
        struct type **stqh_last; \
    }

#define STAILQ_ENTRY(type) \
    struct { \
        struct type *stqe_next; \
    }

#define STAILQ_INIT(head) do { \
    (head)->stqh_first = NULL; \
    (head)->stqh_last = &(head)->stqh_first; \
} while (0)

#define STAILQ_EMPTY(head) ((head)->stqh_first == NULL)
#define STAILQ_FIRST(head) ((head)->stqh_first)

#define STAILQ_REMOVE_HEAD(head, field) do { \
    if (((head)->stqh_first = (head)->stqh_first->field.stqe_next) == NULL) \
        (head)->stqh_last = &(head)->stqh_first; \
} while (0)

#define STAILQ_INSERT_TAIL(head, element, field) do { \
    (element)->field.stqe_next = NULL; \
    *(head)->stqh_last = (element); \
    (head)->stqh_last = &(element)->field.stqe_next; \
} while (0)

#define STAILQ_FOREACH(variable, head, field) \
    for ((variable) = STAILQ_FIRST(head); \
         (variable) != NULL; \
         (variable) = (variable)->field.stqe_next)

#endif
