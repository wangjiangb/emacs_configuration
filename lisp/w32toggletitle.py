# Name: w32toggletitle.py
# Description: toggle windows titlebar on any window
# Author: Martin Svenson
# License: free for all usages/modifications/distributions/whatever.

# Requires: pywin32

import win32api, win32con, win32gui

def toggle_fullscreen(hwnd):
    if is_window_fullscreen(hwnd):
        win32gui.ShowWindow(hwnd, win32con.SW_RESTORE)
    else:
        win32gui.ShowWindow(hwnd, win32con.SW_MAXIMIZE)

def is_window_fullscreen(hwnd):
    placement = win32gui.GetWindowPlacement(hwnd)
    return placement[1] == win32con.SW_MAXIMIZE

def toggle_titlebar(hwnd):
    style = win32con.WS_DLGFRAME | win32con.WS_BORDER
    current = win32api.GetWindowLong(hwnd, win32con.GWL_STYLE)
    win32api.SetWindowLong(hwnd, win32con.GWL_STYLE, style ^ current)
    win32gui.SetWindowPos(hwnd, 0, 0, 0, 0, 0, 
                          win32con.SWP_FRAMECHANGED | win32con.SWP_NOMOVE |
                          win32con.SWP_NOSIZE | win32con.SWP_NOZORDER)

# -- main code --
def main(args = None):
    if len(args) < 2:
        print "Usage: %s hwnd" % args[0]
        return 1
    emacsHwnd = int(args[1])
    toggle_titlebar(emacsHwnd)
    toggle_fullscreen(emacsHwnd)
    return 0

if __name__ == '__main__':
    import sys
    sys.exit(main(sys.argv))
