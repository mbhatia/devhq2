#ifndef DEVHQ_TERMINAL_BRIDGE_H
#define DEVHQ_TERMINAL_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <sys/types.h>

typedef struct DevHQTerminal DevHQTerminal;

typedef struct {
    uint32_t codepoint0, codepoint1, codepoint2, codepoint3;
    uint32_t codepoint4, codepoint5, codepoint6, codepoint7;
    uint8_t codepoint_count;
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
void devhq_terminal_close(DevHQTerminal *terminal);
ssize_t devhq_terminal_read(DevHQTerminal *terminal, uint8_t *buffer, size_t capacity);
ssize_t devhq_terminal_write(DevHQTerminal *terminal, const uint8_t *bytes, size_t count);
bool devhq_terminal_resize(
    DevHQTerminal *terminal,
    uint16_t columns,
    uint16_t rows,
    uint32_t pixel_width,
    uint32_t pixel_height);
pid_t devhq_terminal_pid(const DevHQTerminal *terminal);
bool devhq_terminal_poll_exit(DevHQTerminal *terminal, int *status);
bool devhq_terminal_uses_ghostty(void);
bool devhq_terminal_snapshot(
    DevHQTerminal *terminal,
    DevHQTerminalCell *cells,
    size_t capacity,
    DevHQTerminalSnapshot *snapshot);
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
