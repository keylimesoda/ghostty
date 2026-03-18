#include <assert.h>
#include <stdio.h>
#include <string.h>
#include <ghostty/vt.h>

//! [render-state-update]
int main(void) {
  GhosttyResult result;

  GhosttyTerminal terminal = NULL;
  GhosttyTerminalOptions terminal_opts = {
      .cols = 80,
      .rows = 24,
      .max_scrollback = 10000,
  };
  result = ghostty_terminal_new(NULL, &terminal, terminal_opts);
  assert(result == GHOSTTY_SUCCESS);

  GhosttyRenderState render_state = NULL;
  result = ghostty_render_state_new(NULL, &render_state);
  assert(result == GHOSTTY_SUCCESS);

  const char* first_frame = "first frame\r\n";
  ghostty_terminal_vt_write(
      terminal,
      (const uint8_t*)first_frame,
      strlen(first_frame));
  result = ghostty_render_state_update(render_state, terminal);
  assert(result == GHOSTTY_SUCCESS);

  const char* second_frame = "second frame\r\n";
  ghostty_terminal_vt_write(
      terminal,
      (const uint8_t*)second_frame,
      strlen(second_frame));
  result = ghostty_render_state_update(render_state, terminal);
  assert(result == GHOSTTY_SUCCESS);

  printf("Render state was updated successfully.\n");

  ghostty_render_state_free(render_state);
  ghostty_terminal_free(terminal);
  return 0;
}
//! [render-state-update]
