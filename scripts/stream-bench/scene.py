"""An X11 test app with a tap marker above a terminal-like text viewport."""

import sys
import time
import tkinter as tk


def main():
    x, y, width, height = map(int, sys.argv[1:5])
    scrolling = sys.argv[5] == "scrolling"
    root = tk.Tk()
    root.overrideredirect(True)
    root.geometry(f"{width}x{height}+{x}+{y}")
    canvas = tk.Canvas(root, background="#171b23", highlightthickness=0)
    canvas.pack(fill="both", expand=True)
    marker = canvas.create_rectangle(0, 0, width, height // 5, fill="#bc1828", width=0)
    green = False

    def click(_event):
        nonlocal green
        green = not green
        canvas.itemconfigure(marker, fill="#18bc38" if green else "#bc1828")

    canvas.bind("<ButtonPress-1>", click)
    line_height = 22
    viewport_top = height // 5 + 25
    rows = []
    messages = [
        "GET /workspace/status                 200  2 ms",
        "checking worktree and branch metadata",
        "loaded configuration from project settings",
        "completed display refresh and frame dispatch",
        "waiting for the next input event",
    ]
    for column, left in enumerate(range(24, width - 400, 490)):
        for row in range((height - viewport_top) // line_height + 2):
            line = canvas.create_text(
                left, viewport_top + row * line_height, anchor="nw",
                text=f"{column:02d}.{row:03d}  {messages[(row + column) % len(messages)]}",
                fill=("#d7e2f0", "#93c9f5", "#a5ddb1")[row % 3],
                font=("DejaVu Sans Mono", 11),
            )
            rows.append((line, left, row))

    if scrolling:
        started = time.monotonic()
        cycle = ((height - viewport_top) // line_height + 2) * line_height

        def scroll():
            offset = int((time.monotonic() - started) * 95)
            for item, left, row in rows:
                canvas.coords(item, left, viewport_top + (row * line_height - offset) % cycle)
            root.after(16, scroll)

        scroll()

    root.update()
    print("ready", flush=True)
    root.mainloop()


if __name__ == "__main__":
    main()
