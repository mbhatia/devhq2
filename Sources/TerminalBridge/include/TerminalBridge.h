#ifndef DEVHQ_TERMINAL_BRIDGE_H
#define DEVHQ_TERMINAL_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

typedef struct DevHQTerminal DevHQTerminal;

typedef struct {
    uint32_t grapheme_offset;
    uint32_t grapheme_length;
    uint8_t width;
    uint8_t flags;
    uint8_t has_foreground;
    uint8_t foreground_red, foreground_green, foreground_blue;
    uint8_t has_background;
    uint8_t background_red, background_green, background_blue;
} DevHQTerminalCell;

typedef struct {
    uint16_t columns;
    uint16_t rows;
    uint16_t cursor_column;
    uint16_t cursor_row;
    uint8_t cursor_visible;
    uint8_t cursor_style;
    size_t scrollback_rows;
    size_t scroll_offset;
    // Owned by this snapshot. Each cell refers to a contiguous range in this
    // buffer with its grapheme_offset and grapheme_length fields.
    uint32_t *graphemes;
    size_t grapheme_count;
} DevHQTerminalSnapshot;

enum {
    DEVHQ_TERMINAL_CELL_BOLD = 1 << 0,
    DEVHQ_TERMINAL_CELL_ITALIC = 1 << 1,
    DEVHQ_TERMINAL_CELL_UNDERLINE = 1 << 2,
    DEVHQ_TERMINAL_CELL_STRIKETHROUGH = 1 << 3,
    DEVHQ_TERMINAL_CELL_INVERSE = 1 << 4,
    DEVHQ_TERMINAL_CELL_HYPERLINK = 1 << 5,
};

DevHQTerminal *devhq_terminal_create(
    const char *cwd,
    const char *shell,
    const char *terminfo,
    char *const *argv,
    size_t argv_count,
    uint16_t columns,
    uint16_t rows,
    uint32_t pixel_width,
    uint32_t pixel_height);
// Stop all readers before closing. Other calls may run concurrently with a
// single reader; Ghostty state is internally serialized.
void devhq_terminal_close(DevHQTerminal *terminal);
// Positive: bytes parsed; zero: would block; negative: EOF or read error.
ssize_t devhq_terminal_read(DevHQTerminal *terminal, uint8_t *buffer, size_t capacity);
// Separate gathering from parsing so macOS's 1 KiB PTY reads can overlap VT work.
ssize_t devhq_terminal_read_output(DevHQTerminal *terminal, uint8_t *buffer, size_t capacity);
ssize_t devhq_terminal_gather_output(DevHQTerminal *terminal, uint8_t *buffer, size_t capacity);
size_t devhq_terminal_available_output(DevHQTerminal *terminal);
void devhq_terminal_feed(DevHQTerminal *terminal, const uint8_t *buffer, size_t count);
ssize_t devhq_terminal_write(DevHQTerminal *terminal, const uint8_t *bytes, size_t count);
bool devhq_terminal_resize(
    DevHQTerminal *terminal,
    uint16_t columns,
    uint16_t rows,
    uint32_t pixel_width,
    uint32_t pixel_height);
pid_t devhq_terminal_pid(const DevHQTerminal *terminal);
/// Copies the shell process's current working directory into `buffer`.
/// Pass `NULL, 0` to obtain the required byte count, including no terminator.
size_t devhq_terminal_process_working_directory(
    const DevHQTerminal *terminal, uint8_t *buffer, size_t capacity);
int devhq_terminal_fd(const DevHQTerminal *terminal);
bool devhq_terminal_poll_exit(DevHQTerminal *terminal, int *status);
bool devhq_terminal_uses_ghostty(void);
bool devhq_terminal_snapshot(
    DevHQTerminal *terminal,
    DevHQTerminalCell *cells,
    size_t capacity,
    DevHQTerminalSnapshot *snapshot);
/// Releases the scalar buffer owned by a successful snapshot. The snapshot
/// must be zero-initialized before use and freed once it is no longer needed.
void devhq_terminal_snapshot_free(DevHQTerminalSnapshot *snapshot);
/// Copies a UTF-8 terminal property (title or current working directory).
/// Pass `NULL, 0` to obtain the required byte count.
size_t devhq_terminal_title(DevHQTerminal *terminal, uint8_t *buffer, size_t capacity);
size_t devhq_terminal_working_directory(DevHQTerminal *terminal, uint8_t *buffer, size_t capacity);
bool devhq_terminal_scroll(DevHQTerminal *terminal, intptr_t lines);
size_t devhq_terminal_hyperlink_at(
    DevHQTerminal *terminal,
    uint16_t column,
    uint16_t row,
    uint8_t *buffer,
    size_t capacity);
bool devhq_terminal_key(DevHQTerminal *terminal, int key, uint16_t modifiers);
bool devhq_terminal_paste(DevHQTerminal *terminal, const char *text, size_t count);
bool devhq_terminal_focus(DevHQTerminal *terminal, bool focused);
bool devhq_terminal_mouse(
    DevHQTerminal *terminal,
    int action,
    int button,
    uint16_t modifiers,
    float x,
    float y);

#endif
