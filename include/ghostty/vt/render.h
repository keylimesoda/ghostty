/**
 * @file render.h
 *
 * Render state for creating high performance renderers.
 */

#ifndef GHOSTTY_VT_RENDER_H
#define GHOSTTY_VT_RENDER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <ghostty/vt/allocator.h>
#include <ghostty/vt/color.h>
#include <ghostty/vt/terminal.h>
#include <ghostty/vt/types.h>

#ifdef __cplusplus
extern "C" {
#endif

/** @defgroup render Render State
 *
 * Represents the state required to render a visible screen (a viewport)
 * of a terminal instance. This is stateful and optimized for repeated
 * updates from a single terminal instance and only updating dirty regions
 * of the screen.
 *
 * The key design principle of this API is that it only needs read/write
 * access to the terminal instance during the update call. This allows
 * the render state to minimally impact terminal IO performance and also
 * allows the renderer to be safely multi-threaded (as long as a lock is 
 * held during the update call to ensure exclusive access to the terminal 
 * instance).
 *
 * The basic usage of this API is:
 *
 *   1. Create an empty render state
 *   2. Update it from a terminal instance whenever you need.
 *   3. Read from the render state to get the data needed to draw your frame.
 *
 * ## Example
 *
 * @snippet c-vt-render/src/main.c render-state-update
 *
 * @{
 */

/**
 * Opaque handle to a render state instance.
 *
 * @ingroup render
 */
typedef struct GhosttyRenderState* GhosttyRenderState;

/**
 * Opaque handle to a render-state row iterator.
 *
 * @ingroup render
 */
typedef struct GhosttyRenderStateRowIterator* GhosttyRenderStateRowIterator;

/**
 * Dirty state of a render state after update.
 *
 * @ingroup render
 */
typedef enum {
  /** Not dirty at all; rendering can be skipped. */
  GHOSTTY_RENDER_STATE_DIRTY_FALSE = 0,

  /** Some rows changed; renderer can redraw incrementally. */
  GHOSTTY_RENDER_STATE_DIRTY_PARTIAL = 1,

  /** Global state changed; renderer should redraw everything. */
  GHOSTTY_RENDER_STATE_DIRTY_FULL = 2,
} GhosttyRenderStateDirty;

/**
 * Render-state color information.
 *
 * This struct uses the sized-struct ABI pattern. Initialize with
 * GHOSTTY_INIT_SIZED(GhosttyRenderStateColors) before calling
 * ghostty_render_state_colors_get().
 *
 * Example:
 * @code
 * GhosttyRenderStateColors colors = GHOSTTY_INIT_SIZED(GhosttyRenderStateColors);
 * GhosttyResult result = ghostty_render_state_colors_get(state, &colors);
 * @endcode
 *
 * @ingroup render
 */
typedef struct {
  /** Size of this struct in bytes. Must be set to sizeof(GhosttyRenderStateColors). */
  size_t size;

  /** The default/current background color for the render state. */
  GhosttyColorRgb background;

  /** The default/current foreground color for the render state. */
  GhosttyColorRgb foreground;

  /** The cursor color when explicitly set by terminal state. */
  GhosttyColorRgb cursor;

  /** 
   * True when cursor contains a valid explicit cursor color value. 
   * If this is false, the cursor color should be ignored; it will 
   * contain undefined data.
   * */
  bool cursor_has_value;

  /** The active 256-color palette for this render state. */
  GhosttyColorRgb palette[256];
} GhosttyRenderStateColors;

/**
 * Create a new render state instance.
 *
 * @param allocator Pointer to allocator, or NULL to use the default allocator
 * @param state Pointer to store the created render state handle
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_OUT_OF_MEMORY on allocation
 * failure
 *
 * @ingroup render
 */
GhosttyResult ghostty_render_state_new(const GhosttyAllocator* allocator,
                                       GhosttyRenderState* state);

/**
 * Update a render state instance from a terminal.
 *
 * This consumes terminal/screen dirty state in the same way as the internal
 * render state update path.
 *
 * @param state The render state handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param terminal The terminal handle to read from (NULL returns GHOSTTY_INVALID_VALUE)
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if `state` or
 * `terminal` is NULL, GHOSTTY_OUT_OF_MEMORY if updating the state requires
 * allocation and that allocation fails
 *
 * @ingroup render
 */
GhosttyResult ghostty_render_state_update(GhosttyRenderState state,
                                          GhosttyTerminal terminal);

/**
 * Get the current viewport size from a render state.
 *
 * The returned values are the render-state dimensions in cells. These
 * match the active viewport size from the most recent successful update.
 *
 * @param state The render state handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param[out] out_cols On success, receives the viewport width in cells
 * @param[out] out_rows On success, receives the viewport height in cells
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if `state`,
 *         `out_cols`, or `out_rows` is NULL
 *
 * @ingroup render
 */
GhosttyResult ghostty_render_state_size_get(GhosttyRenderState state,
                                            uint16_t* out_cols,
                                            uint16_t* out_rows);

/**
 * Get the current color information from a render state.
 *
 * This writes as many fields as fit in the caller-provided sized struct.
 * `out_colors->size` must be set by the caller (typically via
 * GHOSTTY_INIT_SIZED(GhosttyRenderStateColors)).
 *
 * @param state The render state handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param[out] out_colors Sized output struct to receive render-state colors
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if `state` or
 *         `out_colors` is NULL, or if `out_colors->size` is smaller than
 *         `sizeof(size_t)`
 *
 * @ingroup render
 */
GhosttyResult ghostty_render_state_colors_get(GhosttyRenderState state,
                                              GhosttyRenderStateColors* out_colors);

/**
 * Get the current dirty state of a render state.
 *
 * @param state The render state handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param[out] out_dirty On success, receives the current dirty state
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if `state` is
 *         NULL
 *
 * @ingroup render
 */
GhosttyResult ghostty_render_state_dirty_get(GhosttyRenderState state,
                                             GhosttyRenderStateDirty* out_dirty);

/**
 * Set the dirty state of a render state.
 *
 * This can be used by callers to clear dirty state after handling updates.
 *
 * @param state The render state handle (NULL returns GHOSTTY_INVALID_VALUE)
 * @param dirty The dirty state to set
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if `state` is
 *         NULL or `dirty` is not a recognized enum value
 *
 * @ingroup render
 */
GhosttyResult ghostty_render_state_dirty_set(GhosttyRenderState state,
                                             GhosttyRenderStateDirty dirty);

/**
 * Create a row iterator for a render state.
 *
 * The iterator borrows from `state`; `state` must outlive the iterator.
 *
 * @param allocator Pointer to allocator, or NULL to use the default allocator
 * @param state The render state handle to iterate (NULL returns GHOSTTY_INVALID_VALUE)
 * @param[out] out_iterator On success, receives the created iterator handle
 * @return GHOSTTY_SUCCESS on success, GHOSTTY_INVALID_VALUE if `state` is
 *         NULL, GHOSTTY_OUT_OF_MEMORY on allocation failure
 *
 * @ingroup render
 */
GhosttyResult ghostty_render_state_row_iterator_new(
    const GhosttyAllocator* allocator,
    GhosttyRenderState state,
    GhosttyRenderStateRowIterator* out_iterator);

/**
 * Free a render-state row iterator.
 *
 * @param iterator The iterator handle to free (may be NULL)
 *
 * @ingroup render
 */
void ghostty_render_state_row_iterator_free(GhosttyRenderStateRowIterator iterator);

/**
 * Free a render state instance.
 *
 * Releases all resources associated with the render state. After this call,
 * the render state handle becomes invalid.
 *
 * @param state The render state handle to free (may be NULL)
 *
 * @ingroup render
 */
void ghostty_render_state_free(GhosttyRenderState state);

/** @} */

#ifdef __cplusplus
}
#endif

#endif /* GHOSTTY_VT_RENDER_H */
