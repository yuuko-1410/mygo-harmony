// windowIds holds the ids of the windows whose pages are on their way: the
// host pushes one before it sets a subwindow's content, and the page of
// that window takes it as it appears, so that each XComponent has a name
// of its own (the Go side finds the window by it).
export const windowIds: number[] = [];
