#include "TerminalBridge.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>
#include <util.h>

#ifdef DEVHQ_USE_GHOSTTY
#include <ghostty/vt.h>
#endif

struct DevHQTerminal {
    int fd;
    pid_t pid;
    bool closed;
    bool exited;
    int exit_status;
#ifdef DEVHQ_USE_GHOSTTY
    GhosttyTerminal ghostty;
    GhosttyRenderState render_state;
    GhosttyKeyEncoder key_encoder;
    GhosttyMouseEncoder mouse_encoder;
    uint16_t columns;
    uint16_t rows;
    uint32_t pixel_width;
    uint32_t pixel_height;
    bool has_size;
#endif
};

static struct winsize make_winsize(
    uint16_t columns, uint16_t rows, uint32_t pixel_width, uint32_t pixel_height) {
    struct winsize value = {0};
    value.ws_col = columns;
    value.ws_row = rows;
    value.ws_xpixel = (unsigned short)(pixel_width > UINT16_MAX ? UINT16_MAX : pixel_width);
    value.ws_ypixel = (unsigned short)(pixel_height > UINT16_MAX ? UINT16_MAX : pixel_height);
    return value;
}

DevHQTerminal *devhq_terminal_create(
    const char *cwd,
    const char *shell,
    const char *terminfo,
    char *const *argv,
    size_t argv_count,
    uint16_t columns,
    uint16_t rows,
    uint32_t pixel_width,
    uint32_t pixel_height) {
    if (!cwd || !shell || columns == 0 || rows == 0 || argv_count > 1024 ||
        (argv_count > 0 && !argv)) return NULL;
    for (size_t index = 0; index < argv_count; ++index) {
        if (!argv[index]) return NULL;
    }
    DevHQTerminal *terminal = calloc(1, sizeof(*terminal));
    if (!terminal) return NULL;
#ifdef DEVHQ_USE_GHOSTTY
    GhosttyTerminalOptions options = {
        .cols = columns,
        .rows = rows,
        .max_scrollback = 10000,
    };
    if (ghostty_terminal_new(NULL, &terminal->ghostty, options) != GHOSTTY_SUCCESS) {
        free(terminal);
        return NULL;
    }
    if (ghostty_render_state_new(NULL, &terminal->render_state) != GHOSTTY_SUCCESS) {
        ghostty_terminal_free(terminal->ghostty);
        free(terminal);
        return NULL;
    }
    if (ghostty_key_encoder_new(NULL, &terminal->key_encoder) != GHOSTTY_SUCCESS) {
        ghostty_render_state_free(terminal->render_state);
        ghostty_terminal_free(terminal->ghostty);
        free(terminal);
        return NULL;
    }
    if (ghostty_mouse_encoder_new(NULL, &terminal->mouse_encoder) != GHOSTTY_SUCCESS) {
        ghostty_key_encoder_free(terminal->key_encoder);
        ghostty_render_state_free(terminal->render_state);
        ghostty_terminal_free(terminal->ghostty);
        free(terminal);
        return NULL;
    }
    if (ghostty_terminal_resize(
            terminal->ghostty, columns, rows, pixel_width / columns, pixel_height / rows)
            != GHOSTTY_SUCCESS ||
        ghostty_render_state_update(terminal->render_state, terminal->ghostty)
            != GHOSTTY_SUCCESS) {
        ghostty_mouse_encoder_free(terminal->mouse_encoder);
        ghostty_key_encoder_free(terminal->key_encoder);
        ghostty_render_state_free(terminal->render_state);
        ghostty_terminal_free(terminal->ghostty);
        free(terminal);
        return NULL;
    }
    terminal->columns = columns;
    terminal->rows = rows;
    terminal->pixel_width = pixel_width;
    terminal->pixel_height = pixel_height;
    terminal->has_size = true;
#endif
    struct winsize size = make_winsize(columns, rows, pixel_width, pixel_height);
    pid_t pid = forkpty(&terminal->fd, NULL, NULL, &size);
    if (pid < 0) {
#ifdef DEVHQ_USE_GHOSTTY
        ghostty_mouse_encoder_free(terminal->mouse_encoder);
        ghostty_key_encoder_free(terminal->key_encoder);
        ghostty_render_state_free(terminal->render_state);
        ghostty_terminal_free(terminal->ghostty);
#endif
        free(terminal);
        return NULL;
    }
    if (pid == 0) {
        (void)setsid();
        if (chdir(cwd) != 0) _exit(127);
        setenv("PWD", cwd, 1);
        bool has_terminfo = terminfo && terminfo[0] && access(terminfo, F_OK) == 0;
        setenv("TERM", has_terminfo ? "xterm-ghostty" : "xterm-256color", 1);
        setenv("COLORTERM", "truecolor", 1);
        if (has_terminfo) setenv("TERMINFO", terminfo, 1);
        if (argv_count > 0) {
            char *child_argv[argv_count + 1];
            for (size_t index = 0; index < argv_count; ++index) child_argv[index] = argv[index];
            child_argv[argv_count] = NULL;
            execvp(child_argv[0], child_argv);
            _exit(127);
        }
        execl(shell, shell, "-l", (char *)NULL);
        _exit(127);
    }
    terminal->pid = pid;
    int flags = fcntl(terminal->fd, F_GETFL, 0);
    if (flags >= 0) (void)fcntl(terminal->fd, F_SETFL, flags | O_NONBLOCK);
    return terminal;
}

bool devhq_terminal_poll_exit(DevHQTerminal *terminal, int *status) {
    if (!terminal) return false;
    if (!terminal->exited) {
        int child_status = 0;
        pid_t result = waitpid(terminal->pid, &child_status, WNOHANG);
        if (result == terminal->pid) {
            terminal->exited = true;
            if (WIFEXITED(child_status)) terminal->exit_status = WEXITSTATUS(child_status);
            else if (WIFSIGNALED(child_status)) terminal->exit_status = 128 + WTERMSIG(child_status);
        }
    }
    if (terminal->exited && status) *status = terminal->exit_status;
    return terminal->exited;
}

void devhq_terminal_close(DevHQTerminal *terminal) {
    if (!terminal) return;
    if (!terminal->closed) {
        terminal->closed = true;
        if (terminal->fd >= 0) {
            close(terminal->fd);
            terminal->fd = -1;
        }
        int status = 0;
        if (!devhq_terminal_poll_exit(terminal, &status)) {
            (void)kill(-terminal->pid, SIGHUP);
            (void)kill(terminal->pid, SIGHUP);
            for (int attempt = 0; attempt < 20; ++attempt) {
                if (devhq_terminal_poll_exit(terminal, &status)) break;
                usleep(10000);
            }
        }
        if (!terminal->exited) {
            (void)kill(-terminal->pid, SIGTERM);
            (void)kill(terminal->pid, SIGTERM);
            usleep(50000);
            (void)devhq_terminal_poll_exit(terminal, &status);
        }
        if (!terminal->exited) {
            (void)kill(-terminal->pid, SIGKILL);
            (void)kill(terminal->pid, SIGKILL);
            (void)waitpid(terminal->pid, &status, 0);
        }
    }
#ifdef DEVHQ_USE_GHOSTTY
    ghostty_mouse_encoder_free(terminal->mouse_encoder);
    ghostty_key_encoder_free(terminal->key_encoder);
    ghostty_render_state_free(terminal->render_state);
    ghostty_terminal_free(terminal->ghostty);
#endif
    free(terminal);
}

ssize_t devhq_terminal_read(DevHQTerminal *terminal, uint8_t *buffer, size_t capacity) {
    if (!terminal || terminal->fd < 0 || !buffer || capacity == 0) return -1;
    ssize_t count = read(terminal->fd, buffer, capacity);
#ifdef DEVHQ_USE_GHOSTTY
    if (count > 0) ghostty_terminal_vt_write(terminal->ghostty, buffer, (size_t)count);
#endif
    return count < 0 && (errno == EAGAIN || errno == EINTR) ? 0 : count;
}

ssize_t devhq_terminal_write(DevHQTerminal *terminal, const uint8_t *bytes, size_t count) {
    if (!terminal || terminal->fd < 0 || !bytes) return -1;
    size_t offset = 0;
    while (offset < count) {
        ssize_t written = write(terminal->fd, bytes + offset, count - offset);
        if (written > 0) offset += (size_t)written;
        else if (written < 0 && errno == EINTR) continue;
        else if (written < 0 && errno == EAGAIN) { usleep(1000); continue; }
        else return -1;
    }
    return (ssize_t)offset;
}

bool devhq_terminal_resize(
    DevHQTerminal *terminal,
    uint16_t columns,
    uint16_t rows,
    uint32_t pixel_width,
    uint32_t pixel_height) {
    if (!terminal || terminal->fd < 0 || columns == 0 || rows == 0) return false;
#ifdef DEVHQ_USE_GHOSTTY
    // libghostty ends synchronized output on resize, so repeated layout passes must be no-ops.
    if (terminal->has_size && terminal->columns == columns && terminal->rows == rows &&
        terminal->pixel_width == pixel_width && terminal->pixel_height == pixel_height) {
        return true;
    }
#endif
    struct winsize size = make_winsize(columns, rows, pixel_width, pixel_height);
    bool result = ioctl(terminal->fd, TIOCSWINSZ, &size) == 0;
#ifdef DEVHQ_USE_GHOSTTY
    if (!result) return false;
    uint32_t cell_width = columns ? pixel_width / columns : 0;
    uint32_t cell_height = rows ? pixel_height / rows : 0;
    bool resized = ghostty_terminal_resize(
        terminal->ghostty, columns, rows, cell_width, cell_height) == GHOSTTY_SUCCESS;
    if (resized) {
        terminal->columns = columns;
        terminal->rows = rows;
        terminal->pixel_width = pixel_width;
        terminal->pixel_height = pixel_height;
        terminal->has_size = true;
    }
    result = resized;
#endif
    return result;
}

pid_t devhq_terminal_pid(const DevHQTerminal *terminal) {
    return terminal ? terminal->pid : -1;
}

bool devhq_terminal_uses_ghostty(void) {
#ifdef DEVHQ_USE_GHOSTTY
    return true;
#else
    return false;
#endif
}

bool devhq_terminal_key(DevHQTerminal *terminal, int key, uint16_t modifiers) {
#ifndef DEVHQ_USE_GHOSTTY
    (void)terminal; (void)key; (void)modifiers;
    return false;
#else
    if (!terminal) return false;
    static const GhosttyKey keys[] = {
        GHOSTTY_KEY_ARROW_UP, GHOSTTY_KEY_ARROW_DOWN, GHOSTTY_KEY_ARROW_LEFT,
        GHOSTTY_KEY_ARROW_RIGHT, GHOSTTY_KEY_HOME, GHOSTTY_KEY_END,
        GHOSTTY_KEY_PAGE_UP, GHOSTTY_KEY_PAGE_DOWN, GHOSTTY_KEY_DELETE,
        GHOSTTY_KEY_BACKSPACE, GHOSTTY_KEY_TAB, GHOSTTY_KEY_ENTER, GHOSTTY_KEY_ESCAPE,
    };
    if (key < 0 || (size_t)key >= sizeof(keys) / sizeof(keys[0])) return false;
    GhosttyKeyEvent event = NULL;
    if (ghostty_key_event_new(NULL, &event) != GHOSTTY_SUCCESS) return false;
    ghostty_key_event_set_action(event, GHOSTTY_KEY_ACTION_PRESS);
    ghostty_key_event_set_key(event, keys[key]);
    ghostty_key_event_set_mods(event, modifiers);
    ghostty_key_encoder_setopt_from_terminal(terminal->key_encoder, terminal->ghostty);
    GhosttyOptionAsAlt alt = GHOSTTY_OPTION_AS_ALT_TRUE;
    ghostty_key_encoder_setopt(
        terminal->key_encoder, GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT, &alt);
    char output[128];
    size_t written = 0;
    GhosttyResult result = ghostty_key_encoder_encode(
        terminal->key_encoder, event, output, sizeof(output), &written);
    ghostty_key_event_free(event);
    if (result != GHOSTTY_SUCCESS) return false;
    return devhq_terminal_write(terminal, (const uint8_t *)output, written) >= 0;
#endif
}

bool devhq_terminal_paste(DevHQTerminal *terminal, const char *text, size_t count) {
#ifndef DEVHQ_USE_GHOSTTY
    (void)terminal; (void)text; (void)count;
    return false;
#else
    if (!terminal || !text) return false;
    bool bracketed = false;
    (void)ghostty_terminal_mode_get(terminal->ghostty, GHOSTTY_MODE_BRACKETED_PASTE, &bracketed);
    char *input = malloc(count);
    if (!input) return false;
    memcpy(input, text, count);
    size_t needed = count + 16;
    char *output = malloc(needed);
    if (!output) { free(input); return false; }
    size_t written = 0;
    GhosttyResult result = ghostty_paste_encode(input, count, bracketed, output, needed, &written);
    if (result == GHOSTTY_OUT_OF_SPACE) {
        char *larger = realloc(output, written);
        if (!larger) { free(input); free(output); return false; }
        output = larger;
        result = ghostty_paste_encode(input, count, bracketed, output, written, &written);
    }
    bool success = result == GHOSTTY_SUCCESS &&
        devhq_terminal_write(terminal, (const uint8_t *)output, written) >= 0;
    free(input);
    free(output);
    return success;
#endif
}

bool devhq_terminal_focus(DevHQTerminal *terminal, bool focused) {
#ifndef DEVHQ_USE_GHOSTTY
    (void)terminal; (void)focused;
    return false;
#else
    if (!terminal) return false;
    bool reporting = false;
    if (ghostty_terminal_mode_get(
            terminal->ghostty, GHOSTTY_MODE_FOCUS_EVENT, &reporting) != GHOSTTY_SUCCESS ||
        !reporting) return true;
    char output[8];
    size_t written = 0;
    if (ghostty_focus_encode(focused ? GHOSTTY_FOCUS_GAINED : GHOSTTY_FOCUS_LOST,
            output, sizeof(output), &written) != GHOSTTY_SUCCESS) return false;
    return devhq_terminal_write(terminal, (const uint8_t *)output, written) >= 0;
#endif
}

bool devhq_terminal_mouse(
    DevHQTerminal *terminal,
    int action,
    int button,
    uint16_t modifiers,
    float x,
    float y) {
#ifndef DEVHQ_USE_GHOSTTY
    (void)terminal; (void)action; (void)button; (void)modifiers; (void)x; (void)y;
    return false;
#else
    if (!terminal || action < 0 || action > 2) return false;
    GhosttyMouseEvent event = NULL;
    if (ghostty_mouse_event_new(NULL, &event) != GHOSTTY_SUCCESS) return false;
    ghostty_mouse_event_set_action(event, (GhosttyMouseAction)action);
    if (button > 0) ghostty_mouse_event_set_button(event, (GhosttyMouseButton)button);
    else ghostty_mouse_event_clear_button(event);
    ghostty_mouse_event_set_mods(event, modifiers);
    ghostty_mouse_event_set_position(event, (GhosttyMousePosition){.x = x, .y = y});
    ghostty_mouse_encoder_setopt_from_terminal(terminal->mouse_encoder, terminal->ghostty);
    char output[128];
    size_t written = 0;
    GhosttyResult result = ghostty_mouse_encoder_encode(
        terminal->mouse_encoder, event, output, sizeof(output), &written);
    ghostty_mouse_event_free(event);
    if (result != GHOSTTY_SUCCESS || written == 0) return false;
    return devhq_terminal_write(terminal, (const uint8_t *)output, written) >= 0;
#endif
}

bool devhq_terminal_snapshot(
    DevHQTerminal *terminal,
    DevHQTerminalCell *cells,
    size_t capacity,
    DevHQTerminalSnapshot *snapshot) {
#ifndef DEVHQ_USE_GHOSTTY
    (void)terminal; (void)cells; (void)capacity; (void)snapshot;
    return false;
#else
    if (!terminal || !cells || !snapshot) return false;
    bool synchronized = false;
    if (ghostty_terminal_mode_get(
            terminal->ghostty, GHOSTTY_MODE_SYNC_OUTPUT, &synchronized) != GHOSTTY_SUCCESS) {
        return false;
    }
    // Keep publishing the last complete frame until the application ends its synchronized update.
    if (!synchronized &&
        ghostty_render_state_update(terminal->render_state, terminal->ghostty) != GHOSTTY_SUCCESS) {
        return false;
    }
    uint16_t columns = 0, rows = 0;
    if (ghostty_render_state_get(
            terminal->render_state, GHOSTTY_RENDER_STATE_DATA_COLS, &columns) != GHOSTTY_SUCCESS ||
        ghostty_render_state_get(
            terminal->render_state, GHOSTTY_RENDER_STATE_DATA_ROWS, &rows) != GHOSTTY_SUCCESS ||
        capacity < (size_t)columns * rows) return false;
    memset(cells, 0, sizeof(*cells) * (size_t)columns * rows);
    memset(snapshot, 0, sizeof(*snapshot));
    snapshot->columns = columns;
    snapshot->rows = rows;
    (void)ghostty_render_state_get(terminal->render_state,
        GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_X, &snapshot->cursor_column);
    (void)ghostty_render_state_get(terminal->render_state,
        GHOSTTY_RENDER_STATE_DATA_CURSOR_VIEWPORT_Y, &snapshot->cursor_row);
    bool cursor_visible = false;
    (void)ghostty_render_state_get(terminal->render_state,
        GHOSTTY_RENDER_STATE_DATA_CURSOR_VISIBLE, &cursor_visible);
    snapshot->cursor_visible = cursor_visible;
    GhosttyRenderStateCursorVisualStyle cursor_style =
        GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BLOCK;
    (void)ghostty_render_state_get(terminal->render_state,
        GHOSTTY_RENDER_STATE_DATA_CURSOR_VISUAL_STYLE, &cursor_style);
    snapshot->cursor_style = cursor_style == GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_BAR ? 1 :
        (cursor_style == GHOSTTY_RENDER_STATE_CURSOR_VISUAL_STYLE_UNDERLINE ? 2 : 0);

    GhosttyRenderStateRowIterator iterator = NULL;
    GhosttyRenderStateRowCells row_cells = NULL;
    if (ghostty_render_state_row_iterator_new(NULL, &iterator) != GHOSTTY_SUCCESS ||
        ghostty_render_state_row_cells_new(NULL, &row_cells) != GHOSTTY_SUCCESS) goto fail;
    if (ghostty_render_state_get(terminal->render_state,
            GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &iterator) != GHOSTTY_SUCCESS) goto fail;
    size_t y = 0;
    while (y < rows && ghostty_render_state_row_iterator_next(iterator)) {
        if (ghostty_render_state_row_get(iterator,
                GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &row_cells) != GHOSTTY_SUCCESS) goto fail;
        size_t x = 0;
        while (x < columns && ghostty_render_state_row_cells_next(row_cells)) {
            DevHQTerminalCell *output = &cells[y * columns + x];
            uint32_t length = 0;
            (void)ghostty_render_state_row_cells_get(row_cells,
                GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_LEN, &length);
            if (length > 0) {
                uint32_t copied = length > 8 ? 8 : length;
                uint32_t stack_codepoints[8] = {0};
                uint32_t *codepoints = length > 8 ? calloc(length, sizeof(uint32_t)) : stack_codepoints;
                if (!codepoints) goto fail;
                (void)ghostty_render_state_row_cells_get(row_cells,
                    GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, codepoints);
                memcpy(&output->codepoint0, codepoints, copied * sizeof(uint32_t));
                output->codepoint_count = (uint8_t)copied;
                if (codepoints != stack_codepoints) free(codepoints);
            }
            GhosttyCell raw = 0;
            GhosttyCellWide wide = GHOSTTY_CELL_WIDE_NARROW;
            (void)ghostty_render_state_row_cells_get(row_cells,
                GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw);
            (void)ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide);
            bool has_hyperlink = false;
            (void)ghostty_cell_get(raw, GHOSTTY_CELL_DATA_HAS_HYPERLINK, &has_hyperlink);
            if (has_hyperlink) output->flags |= DEVHQ_TERMINAL_CELL_HYPERLINK;
            output->width = wide == GHOSTTY_CELL_WIDE_WIDE ? 2 :
                (wide == GHOSTTY_CELL_WIDE_SPACER_TAIL ? 0 : 1);
            GhosttyStyle style = GHOSTTY_INIT_SIZED(GhosttyStyle);
            if (ghostty_render_state_row_cells_get(row_cells,
                    GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style) == GHOSTTY_SUCCESS) {
                if (style.bold) output->flags |= DEVHQ_TERMINAL_CELL_BOLD;
                if (style.italic) output->flags |= DEVHQ_TERMINAL_CELL_ITALIC;
                if (style.underline) output->flags |= DEVHQ_TERMINAL_CELL_UNDERLINE;
                if (style.strikethrough) output->flags |= DEVHQ_TERMINAL_CELL_STRIKETHROUGH;
                if (style.inverse) output->flags |= DEVHQ_TERMINAL_CELL_INVERSE;
            }
            GhosttyColorRgb color;
            if (ghostty_render_state_row_cells_get(row_cells,
                    GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &color) == GHOSTTY_SUCCESS) {
                output->has_foreground = 1;
                output->foreground_red = color.r;
                output->foreground_green = color.g;
                output->foreground_blue = color.b;
            }
            if (ghostty_render_state_row_cells_get(row_cells,
                    GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &color) == GHOSTTY_SUCCESS) {
                output->has_background = 1;
                output->background_red = color.r;
                output->background_green = color.g;
                output->background_blue = color.b;
            }
            ++x;
        }
        ++y;
    }
    ghostty_render_state_row_cells_free(row_cells);
    ghostty_render_state_row_iterator_free(iterator);
    return true;
fail:
    ghostty_render_state_row_cells_free(row_cells);
    ghostty_render_state_row_iterator_free(iterator);
    return false;
#endif
}

size_t devhq_terminal_hyperlink_at(
    DevHQTerminal *terminal,
    uint16_t column,
    uint16_t row,
    uint8_t *buffer,
    size_t capacity) {
#ifndef DEVHQ_USE_GHOSTTY
    (void)terminal; (void)column; (void)row; (void)buffer; (void)capacity;
    return 0;
#else
    if (!terminal) return 0;
    GhosttyPoint point = {0};
    point.tag = GHOSTTY_POINT_TAG_VIEWPORT;
    point.value.coordinate.x = column;
    point.value.coordinate.y = row;
    GhosttyGridRef reference = GHOSTTY_INIT_SIZED(GhosttyGridRef);
    if (ghostty_terminal_grid_ref(terminal->ghostty, point, &reference) != GHOSTTY_SUCCESS)
        return 0;
    size_t required = 0;
    GhosttyResult result = ghostty_grid_ref_hyperlink_uri(&reference, NULL, 0, &required);
    if (result != GHOSTTY_SUCCESS && result != GHOSTTY_OUT_OF_SPACE) return 0;
    if (required == 0 || !buffer || capacity < required) return required;
    size_t written = 0;
    result = ghostty_grid_ref_hyperlink_uri(&reference, buffer, capacity, &written);
    return result == GHOSTTY_SUCCESS ? written : 0;
#endif
}
