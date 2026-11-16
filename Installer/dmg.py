import json
import os.path

app = defines["app"]
name = os.path.basename(app)
with open(defines["layout"]) as file:
    layout = json.load(file)

format = defines.get("format", "ULMO")
files = [app]
symlinks = {"Applications": "/Applications"}
icon = defines["icon"]
background = defines["background"]

window_rect = ((200, 160), (layout["width"], layout["height"] + layout["titleBar"]))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
sidebar_width = 0
show_icon_preview = False
include_icon_view_settings = True
include_list_view_settings = False

arrange_by = None
grid_offset = (0, 0)
grid_spacing = 100
scroll_position = (0, 0)
label_pos = "bottom"
icon_size = layout["iconSize"]
text_size = layout["textSize"]
icon_locations = {
    name: tuple(layout["app"]),
    "Applications": tuple(layout["applications"]),
}
