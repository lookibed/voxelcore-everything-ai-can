/*
 * Платформенный слой doomgeneric для хоста VoxelCore (C -> wasm -> Lua через Spider).
 *
 * Модуль собирается с wasi-libc, но без импортов: все системные вызовы WASI,
 * которые тянет libc, определены здесь. Файловая система виртуальная: один
 * преоткрытый каталог "/" с единственным файлом IWAD, который хост кладёт в
 * память модуля. Время, клавиши и кадр ходят через экспортируемые функции.
 */

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

#include "doomgeneric.h"
#include "doomkeys.h"
#include "doomtype.h"
#include "i_video.h"

extern boolean palette_changed;

#define EXPORT(name) __attribute__((export_name(#name)))

/* ------------------------------------------------------------------ состояние */

static const uint8_t *wad_data;
static uint32_t wad_size;
static char wad_name[64] = "doom1.wad";

static uint32_t host_time_ms;
static uint32_t virtual_time_ms;

#define KEYQUEUE_SIZE 64
static uint16_t key_queue[KEYQUEUE_SIZE];
static uint32_t key_write, key_read;

static uint32_t frame_count;
static int exited;
static int exit_code;

#define LOG_CAPACITY 16384
static char log_buffer[LOG_CAPACITY];
static uint32_t log_size;

static void log_append(const uint8_t *data, uint32_t len) {
    for (uint32_t i = 0; i < len; i++) {
        if (log_size < LOG_CAPACITY) {
            log_buffer[log_size++] = (char)data[i];
        }
    }
}

/* ------------------------------------------------------------------ doomgeneric */

void DG_Init(void) {}

void DG_DrawFrame(void) { frame_count++; }

/* Время хоста задаётся перед каждым тиком. Doom ждёт следующий тик через
   DG_SleepMs, поэтому сон двигает виртуальные часы вперёд, иначе цикл ожидания
   внутри одного вызова никогда бы не закончился. */
void DG_SleepMs(uint32_t ms) { virtual_time_ms += ms; }

uint32_t DG_GetTicksMs(void) {
    if (virtual_time_ms < host_time_ms) {
        virtual_time_ms = host_time_ms;
    }
    return virtual_time_ms;
}

int DG_GetKey(int *pressed, unsigned char *key) {
    if (key_read == key_write) {
        return 0;
    }
    uint16_t data = key_queue[key_read];
    key_read = (key_read + 1) % KEYQUEUE_SIZE;
    *pressed = data >> 8;
    *key = (unsigned char)(data & 0xFF);
    return 1;
}

void DG_SetWindowTitle(const char *title) { (void)title; }

/* ------------------------------------------------------------------ API для хоста */

EXPORT(dgv_alloc) void *dgv_alloc(int size) { return malloc((size_t)size); }

/* Имя IWAD важно: по нему DOOM определяет игру (doom1.wad, doom.wad, doom2.wad, ...).
   Вызывать до dgv_init; имя кладётся в буфер, полученный через dgv_alloc. */
EXPORT(dgv_set_wad_name) int dgv_set_wad_name(const char *name, int len) {
    if (len <= 0 || len >= (int)sizeof(wad_name)) {
        return 0;
    }
    memcpy(wad_name, name, (size_t)len);
    wad_name[len] = 0;
    return 1;
}

/* mode: 0 — обычная игра, 1 — -timedemo demo1 (бенчмарк), 2 — -timedemo demo1 без звука/музыки */
EXPORT(dgv_init) int dgv_init(const uint8_t *data, int size, int mode) {
    static char *argv_play[] = {"doom", "-iwad", wad_name, "-nosound", "-nomusic", 0};
    static char *argv_timedemo[] = {"doom", "-iwad", wad_name, "-nosound", "-nomusic", "-timedemo", "demo1", 0};
    wad_data = data;
    wad_size = (uint32_t)size;
    if (mode == 1 || mode == 2) {
        doomgeneric_Create(7, argv_timedemo);
    } else {
        doomgeneric_Create(5, argv_play);
    }
    return exited ? 0 : 1;
}

EXPORT(dgv_tick) int dgv_tick(uint32_t now_ms) {
    host_time_ms = now_ms;
    doomgeneric_Tick();
    return exited ? 0 : 1;
}

EXPORT(dgv_key) void dgv_key(int pressed, int key) {
    key_queue[key_write] = (uint16_t)(((pressed ? 1 : 0) << 8) | (key & 0xFF));
    key_write = (key_write + 1) % KEYQUEUE_SIZE;
    if (key_write == key_read) {
        key_read = (key_read + 1) % KEYQUEUE_SIZE; /* переполнение: теряем самое старое */
    }
}

EXPORT(dgv_screen_ptr) uint8_t *dgv_screen_ptr(void) { return (uint8_t *)DG_ScreenBuffer; }
EXPORT(dgv_screen_width) int dgv_screen_width(void) { return DOOMGENERIC_RESX; }
EXPORT(dgv_screen_height) int dgv_screen_height(void) { return DOOMGENERIC_RESY; }

/* палитра: 256 записей по 4 байта (b, g, r, a) */
EXPORT(dgv_palette_ptr) uint8_t *dgv_palette_ptr(void) { return (uint8_t *)colors; }
EXPORT(dgv_palette_changed) int dgv_palette_changed(void) {
    int changed = palette_changed;
    palette_changed = 0;
    return changed;
}

EXPORT(dgv_frame_count) uint32_t dgv_frame_count(void) { return frame_count; }
EXPORT(dgv_exited) int dgv_exited(void) { return exited; }
EXPORT(dgv_exit_code) int dgv_exit_code(void) { return exit_code; }
EXPORT(dgv_log_ptr) char *dgv_log_ptr(void) { return log_buffer; }
EXPORT(dgv_log_size) uint32_t dgv_log_size(void) { return log_size; }
EXPORT(dgv_log_clear) void dgv_log_clear(void) { log_size = 0; }

/* ------------------------------------------------------------------ WASI без импортов */

#define WASI_ESUCCESS 0
#define WASI_EACCES 2
#define WASI_EBADF 8
#define WASI_EINVAL 28
#define WASI_EISDIR 31
#define WASI_ENOENT 44
#define WASI_ENOSYS 52
#define WASI_ENOTDIR 54
#define WASI_ESPIPE 70

#define FILETYPE_CHARACTER_DEVICE 2
#define FILETYPE_DIRECTORY 3
#define FILETYPE_REGULAR_FILE 4

#define PREOPEN_FD 3
#define FIRST_FILE_FD 4
#define MAX_OPEN_FILES 8

typedef struct {
    int used;
    uint32_t position;
} open_file_t;

static open_file_t open_files[MAX_OPEN_FILES];

static open_file_t *file_of(int32_t fd) {
    if (fd < FIRST_FILE_FD || fd >= FIRST_FILE_FD + MAX_OPEN_FILES) {
        return 0;
    }
    open_file_t *file = &open_files[fd - FIRST_FILE_FD];
    return file->used ? file : 0;
}

static void put_u64(uint8_t *p, uint64_t v) { memcpy(p, &v, 8); }
static void put_u32(uint8_t *p, uint32_t v) { memcpy(p, &v, 4); }

typedef struct {
    uint32_t buf;
    uint32_t len;
} iovec_t;

int32_t __imported_wasi_snapshot_preview1_args_sizes_get(int32_t argc, int32_t size) {
    put_u32((uint8_t *)argc, 0);
    put_u32((uint8_t *)size, 0);
    return WASI_ESUCCESS;
}
int32_t __imported_wasi_snapshot_preview1_args_get(int32_t argv, int32_t buf) {
    (void)argv; (void)buf;
    return WASI_ESUCCESS;
}
int32_t __imported_wasi_snapshot_preview1_environ_sizes_get(int32_t count, int32_t size) {
    put_u32((uint8_t *)count, 0);
    put_u32((uint8_t *)size, 0);
    return WASI_ESUCCESS;
}
int32_t __imported_wasi_snapshot_preview1_environ_get(int32_t environ, int32_t buf) {
    (void)environ; (void)buf;
    return WASI_ESUCCESS;
}
int32_t __imported_wasi_snapshot_preview1_clock_time_get(int32_t id, int64_t precision, int32_t out) {
    (void)id; (void)precision;
    put_u64((uint8_t *)out, (uint64_t)DG_GetTicksMs() * 1000000ull);
    return WASI_ESUCCESS;
}
int32_t __imported_wasi_snapshot_preview1_clock_res_get(int32_t id, int32_t out) {
    (void)id;
    put_u64((uint8_t *)out, 1000000ull);
    return WASI_ESUCCESS;
}

_Noreturn void __imported_wasi_snapshot_preview1_proc_exit(int32_t code) {
    exited = 1;
    exit_code = code;
    __builtin_trap();
}

int32_t __imported_wasi_snapshot_preview1_fd_prestat_get(int32_t fd, int32_t out) {
    if (fd != PREOPEN_FD) {
        return WASI_EBADF;
    }
    uint8_t *p = (uint8_t *)out;
    p[0] = 0; /* dir */
    put_u32(p + 4, 1); /* strlen("/") */
    return WASI_ESUCCESS;
}
int32_t __imported_wasi_snapshot_preview1_fd_prestat_dir_name(int32_t fd, int32_t path, int32_t len) {
    if (fd != PREOPEN_FD || len < 1) {
        return WASI_EBADF;
    }
    ((uint8_t *)path)[0] = '/';
    return WASI_ESUCCESS;
}

int32_t __imported_wasi_snapshot_preview1_fd_fdstat_get(int32_t fd, int32_t out) {
    uint8_t *p = (uint8_t *)out;
    memset(p, 0, 24);
    if (fd >= 0 && fd <= 2) {
        p[0] = FILETYPE_CHARACTER_DEVICE;
    } else if (fd == PREOPEN_FD) {
        p[0] = FILETYPE_DIRECTORY;
    } else if (file_of(fd)) {
        p[0] = FILETYPE_REGULAR_FILE;
    } else {
        return WASI_EBADF;
    }
    put_u64(p + 8, ~0ull);
    put_u64(p + 16, ~0ull);
    return WASI_ESUCCESS;
}
int32_t __imported_wasi_snapshot_preview1_fd_fdstat_set_flags(int32_t fd, int32_t flags) {
    (void)fd; (void)flags;
    return WASI_ENOSYS;
}

static void fill_filestat(uint8_t *p, uint8_t filetype, uint64_t size) {
    memset(p, 0, 64);
    p[16] = filetype;
    put_u64(p + 24, 1);
    put_u64(p + 32, size);
}

int32_t __imported_wasi_snapshot_preview1_fd_filestat_get(int32_t fd, int32_t out) {
    if (fd >= 0 && fd <= 2) {
        fill_filestat((uint8_t *)out, FILETYPE_CHARACTER_DEVICE, 0);
    } else if (fd == PREOPEN_FD) {
        fill_filestat((uint8_t *)out, FILETYPE_DIRECTORY, 0);
    } else if (file_of(fd)) {
        fill_filestat((uint8_t *)out, FILETYPE_REGULAR_FILE, wad_size);
    } else {
        return WASI_EBADF;
    }
    return WASI_ESUCCESS;
}

static int is_wad_path(const uint8_t *path, int32_t len) {
    /* допускаем "doom1.wad" и "./doom1.wad" */
    if (len >= 2 && path[0] == '.' && path[1] == '/') {
        path += 2;
        len -= 2;
    }
    return (size_t)len == strlen(wad_name) && memcmp(path, wad_name, (size_t)len) == 0;
}

int32_t __imported_wasi_snapshot_preview1_path_open(int32_t dirfd, int32_t dirflags, int32_t path, int32_t path_len,
                                                    int32_t oflags, int64_t rights_base, int64_t rights_inheriting,
                                                    int32_t fdflags, int32_t out_fd) {
    (void)dirflags; (void)rights_base; (void)rights_inheriting; (void)fdflags;
    if (dirfd != PREOPEN_FD) {
        return WASI_EBADF;
    }
    if (path_len == 0 || (path_len == 1 && ((uint8_t *)path)[0] == '.')) {
        return WASI_EISDIR;
    }
    if (!wad_data || !is_wad_path((const uint8_t *)path, path_len)) {
        return (oflags & 1) ? WASI_EACCES : WASI_ENOENT; /* создавать файлы некуда */
    }
    if (oflags & (2 | 8)) { /* O_DIRECTORY, O_TRUNC */
        return (oflags & 2) ? WASI_ENOTDIR : WASI_EACCES;
    }
    for (int i = 0; i < MAX_OPEN_FILES; i++) {
        if (!open_files[i].used) {
            open_files[i].used = 1;
            open_files[i].position = 0;
            put_u32((uint8_t *)out_fd, (uint32_t)(FIRST_FILE_FD + i));
            return WASI_ESUCCESS;
        }
    }
    return WASI_EACCES;
}

int32_t __imported_wasi_snapshot_preview1_path_filestat_get(int32_t dirfd, int32_t flags, int32_t path, int32_t path_len,
                                                            int32_t out) {
    (void)flags;
    if (dirfd != PREOPEN_FD) {
        return WASI_EBADF;
    }
    if (wad_data && is_wad_path((const uint8_t *)path, path_len)) {
        fill_filestat((uint8_t *)out, FILETYPE_REGULAR_FILE, wad_size);
        return WASI_ESUCCESS;
    }
    return WASI_ENOENT;
}

int32_t __imported_wasi_snapshot_preview1_fd_close(int32_t fd) {
    open_file_t *file = file_of(fd);
    if (file) {
        file->used = 0;
    }
    return WASI_ESUCCESS;
}

int32_t __imported_wasi_snapshot_preview1_fd_read(int32_t fd, int32_t iovs, int32_t iovs_len, int32_t out_read) {
    open_file_t *file = file_of(fd);
    if (!file) {
        put_u32((uint8_t *)out_read, 0);
        return (fd == 0) ? WASI_ESUCCESS : WASI_EBADF;
    }
    uint32_t total = 0;
    const iovec_t *vec = (const iovec_t *)iovs;
    for (int32_t i = 0; i < iovs_len; i++) {
        uint32_t remaining = file->position < wad_size ? wad_size - file->position : 0;
        uint32_t n = vec[i].len < remaining ? vec[i].len : remaining;
        memcpy((void *)vec[i].buf, wad_data + file->position, n);
        file->position += n;
        total += n;
        if (n < vec[i].len) {
            break;
        }
    }
    put_u32((uint8_t *)out_read, total);
    return WASI_ESUCCESS;
}

int32_t __imported_wasi_snapshot_preview1_fd_pread(int32_t fd, int32_t iovs, int32_t iovs_len, int64_t offset,
                                                   int32_t out_read) {
    open_file_t *file = file_of(fd);
    if (!file) {
        return WASI_EBADF;
    }
    uint32_t saved = file->position;
    file->position = (uint32_t)offset;
    int32_t result = __imported_wasi_snapshot_preview1_fd_read(fd, iovs, iovs_len, out_read);
    file->position = saved;
    return result;
}

int32_t __imported_wasi_snapshot_preview1_fd_write(int32_t fd, int32_t iovs, int32_t iovs_len, int32_t out_written) {
    uint32_t total = 0;
    const iovec_t *vec = (const iovec_t *)iovs;
    for (int32_t i = 0; i < iovs_len; i++) {
        if (fd == 1 || fd == 2) {
            log_append((const uint8_t *)vec[i].buf, vec[i].len);
        }
        total += vec[i].len;
    }
    put_u32((uint8_t *)out_written, total);
    return (fd == 1 || fd == 2) ? WASI_ESUCCESS : WASI_EBADF;
}

int32_t __imported_wasi_snapshot_preview1_fd_seek(int32_t fd, int64_t offset, int32_t whence, int32_t out_position) {
    open_file_t *file = file_of(fd);
    if (!file) {
        return (fd >= 0 && fd <= 2) ? WASI_ESPIPE : WASI_EBADF;
    }
    int64_t base = whence == 0 ? 0 : whence == 1 ? (int64_t)file->position : (int64_t)wad_size;
    int64_t target = base + offset;
    if (target < 0) {
        return WASI_EINVAL;
    }
    file->position = (uint32_t)target;
    put_u64((uint8_t *)out_position, (uint64_t)target);
    return WASI_ESUCCESS;
}

int32_t __imported_wasi_snapshot_preview1_fd_tell(int32_t fd, int32_t out_position) {
    open_file_t *file = file_of(fd);
    if (!file) {
        return WASI_EBADF;
    }
    put_u64((uint8_t *)out_position, file->position);
    return WASI_ESUCCESS;
}

/* i_system.c пытается показать окно ошибки через system("zenity ..."); оболочки нет */
int system(const char *command) {
    (void)command;
    return -1;
}

/* запись на виртуальную ФС не поддерживается: сохранения и конфиг просто не пишутся */
int32_t __imported_wasi_snapshot_preview1_path_create_directory(int32_t fd, int32_t path, int32_t len) {
    (void)fd; (void)path; (void)len;
    return WASI_EACCES;
}
int32_t __imported_wasi_snapshot_preview1_path_remove_directory(int32_t fd, int32_t path, int32_t len) {
    (void)fd; (void)path; (void)len;
    return WASI_EACCES;
}
int32_t __imported_wasi_snapshot_preview1_path_unlink_file(int32_t fd, int32_t path, int32_t len) {
    (void)fd; (void)path; (void)len;
    return WASI_EACCES;
}
int32_t __imported_wasi_snapshot_preview1_path_rename(int32_t fd, int32_t old_path, int32_t old_len, int32_t new_fd,
                                                      int32_t new_path, int32_t new_len) {
    (void)fd; (void)old_path; (void)old_len; (void)new_fd; (void)new_path; (void)new_len;
    return WASI_EACCES;
}
