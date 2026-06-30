const std = @import("std");
const vaxis = @import("vaxis");
const Cell = vaxis.Cell;
const TextInput = vaxis.widgets.TextInput;

const Event = union(enum) {
    key_press: vaxis.Key,
    winsize: vaxis.Winsize,
    focus_in,
    foo: u8,
};

pub fn main(init: std.process.Init) !void {
    std.debug.print("Starting tuey ... {s}", .{"test run"});
    
    const io = init.io;
    const alloc = init.gpa;

    // Initialize a try
    var buffer: [1024]u8 = undefined;
    var tty = try vaxis.Tty.init(io, &buffer);
    defer tty.deinit();

    // Initialize Vaxis
    var vx = try vaxis.init(io, alloc, init.environ_map, .{});
    defer vx.deinit(alloc, tty.writer());

    std.debug.print("after deinit", .{});

    // Initialize event loop w/ intrustive init to create stable pointers
    var loop: vaxis.Loop(Event) = .init(io, &tty, &vx);

    // start the read loop
    try loop.start();
    defer loop.stop();

    // try to enter the alternate screen
    try vx.enterAltScreen(tty.writer());

    // set the color index to 0
    var color_idx: u8 = 0;

    // init a text input widget
    var text_input = TextInput.init(alloc);
    defer text_input.deinit();

    // Sends queries to terminal to detect certain features.  Called after entering alt screen
    try vx.queryTerminal(tty.writer(), .fromSeconds(1));

    std.log.debug("in_band_resize after query: {}", .{vx.state.in_band_resize});

    // Force signal-driven resize: vaxis's winsizeCallback silently fails when
    // called from POSIX signal handler context because it tries to use
    // std.Io.Mutex (not async-signal-safe in the new io model). Keeping
    // in_band_resize false so the SIGWINCH path stays active is correct, but
    // the postEvent call itself is the actual broken link in this vaxis commit.
    vx.state.in_band_resize = false;

    var oldwin: vaxis.Window = vx.window();

    while (true) {
        // nextEvent blocks event loop until an event is in the queue
        const event = try loop.nextEvent();

        // exhaustive switching
        switch (event) {
            .key_press => |key| {
                color_idx = switch (color_idx) {
                    255 => 0,
                    else => color_idx + 1,
                };
                if (key.matches('c', .{ .ctrl = true })) {
                    break;
                } else if (key.matches('l', .{ .ctrl = true })) {
                    vx.queueRefresh();
                } else {
                    try text_input.update(.{ .key_press = key });
                }
            },
            .winsize => |ws| {
                try vx.resize(alloc, tty.writer(), ws);
                std.log.debug("winsize: {any}", .{ws});
            },
            else => {}
        }

        const win: vaxis.Window = vx.window();

        if (!std.meta.eql(win, oldwin)) {
            std.log.debug("win changed: {}x{} -> {}x{}", .{ oldwin.width, oldwin.height, win.width, win.height });
        }

        win.clear();
        // Create a style
        const style: vaxis.Style = .{
            .fg = .{ .index = color_idx },
        };

        // Create a bordered child window
        const child = win.child(.{
            .x_off = win.width / 2 - 20,
            .y_off = win.height / 2 - 3,
            .width = 40 ,
            .height = 3 ,
            .border = .{
                .where = .all,
                .style = style,
            },
        });

        // Draw the text_input in the child window
        text_input.draw(child);

        // Render the screen. Using a buffered writer will offer much better
	// performance, but is not required
        try vx.render(tty.writer());
        oldwin = win;

    }
}

