/** Presentation geometry derived from measured, safe-area-constrained container widths. */
export const COVER_ASPECT = 0.7;
const clamp = (value: number, min: number, max: number) => Math.min(max, Math.max(min, value));

export const LIBRARY_MAX_WIDTH = 1280;
export const LIBRARY_GUTTER = 20;
export const LIBRARY_GAP = 16;
/**
 * Roomy displays get a bookshelf of cover tiles; phones, short landscape windows and
 * enlarged text get horizontal cards whose cover scales with the column width.
 */
export function libraryGrid(width: number, height: number, fontScale: number) {
  const content = Math.max(0, Math.min(width, LIBRARY_MAX_WIDTH) - LIBRARY_GUTTER * 2);
  const largeText = fontScale > 1.3;
  if (!largeText && content >= 520 && height >= 600) {
    return {columns: clamp(Math.round((content + LIBRARY_GAP) / (220 + LIBRARY_GAP)), 2, 6), tiles: true, coverWidth: 0};
  }
  const columns = !largeText && content >= 680 ? 2 : 1;
  const column = (content - LIBRARY_GAP * (columns - 1)) / columns;
  return {columns, tiles: false, coverWidth: Math.round(clamp(column * 0.36, 100, 168))};
}

export const PAGE_GRID_PADDING = 8;
const PAGE_CELL_INSET = 6; // 4 padding + 2 selection border
/**
 * Whole-pixel page overview cells so getItemLayout offsets match the rendered rows exactly.
 * The stored thumbnail size keeps its meaning: 0 shows the most pages, 1 the largest pages.
 */
export function pageGrid(width: number, fontScale: number, thumbnailSize: number) {
  const available = Math.max(1, width - PAGE_GRID_PADDING * 2);
  const size = clamp(thumbnailSize, 0, 1);
  const minimum = fontScale > 1.8 || size >= 0.8 ? 1 : 2;
  const columns = clamp(Math.round(available / (120 + size * 240)), minimum, 12);
  const cellWidth = Math.max(1, Math.floor(available / columns));
  const imageHeight = Math.max(1, Math.round((cellWidth - PAGE_CELL_INSET * 2) / COVER_ASPECT));
  const labelHeight = Math.ceil(26 * clamp(fontScale, 1, 2));
  return {columns, cellWidth, imageHeight, labelHeight, rowHeight: imageHeight + PAGE_CELL_INSET * 2 + labelHeight,
    sidePadding: Math.max(0, (width - cellWidth * columns) / 2)};
}
