import {libraryGrid, pageGrid} from '../layout';

it('makes phone covers larger and gives tablets full-width cover tiles', () => {
  expect(libraryGrid(390, 844, 1)).toMatchObject({columns: 1, tiles: false, coverWidth: 126});
  expect(libraryGrid(768, 1024, 1)).toMatchObject({columns: 3, tiles: true});
  expect(libraryGrid(1024, 768, 1)).toMatchObject({columns: 4, tiles: true});
  expect(libraryGrid(844, 390, 1)).toMatchObject({columns: 2, tiles: false});
  expect(libraryGrid(1024, 768, 1.5)).toMatchObject({columns: 1, tiles: false});
});

it.each([304, 375, 560, 744, 984, 1098])('keeps enlarged page cells within a measured %sdp container across the preference range', width => {
  let previousWidth = 0;
  for (let size = 0; size <= 1; size += 0.05) {
    const grid = pageGrid(width, 1, size);
    expect(grid.cellWidth).toBeGreaterThanOrEqual(previousWidth);
    expect(grid.cellWidth * grid.columns + grid.sidePadding * 2).toBeCloseTo(width);
    expect(grid.imageHeight).toBeGreaterThan(0);
    expect(Number.isInteger(grid.rowHeight)).toBe(true);
    previousWidth = grid.cellWidth;
  }
});

it('provides readable default page sizes on a phone and a large tablet', () => {
  expect(pageGrid(375, 1, 0.25).cellWidth).toBeGreaterThanOrEqual(170);
  expect(pageGrid(1098, 1, 0.25).cellWidth).toBeGreaterThanOrEqual(175);
  expect(pageGrid(375, 1, 1).columns).toBe(1);
});
