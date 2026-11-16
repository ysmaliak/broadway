# The Broadway name and icon

The code in this repository is under the [MIT License](LICENSE). You may use, copy, change and share it, for any purpose, as that licence says. Nothing here takes any of that away.

The licence covers the code. It gives no right to the name. "Broadway" as the name of this browser, and its icon as the mark people know it by, are the project's own. They tell people which copy comes from this project and gets its updates and support.

- **Talking about Broadway** is always fine: writing about it, linking to it, saying that your project works with it or is based on it.
- **Building it for yourself** is fine, with the name and icon as they are. That is what `./build.sh` does.
- **Shipping a fork to other people** needs a name and an icon of its own, and its own update feed (`FEED` and `FEED_KEY` in `build.sh`). A bundle id of its own keeps its settings apart from Broadway's too, though `com.ysmaliak.broadway` is written in several places. You can say that it is based on Broadway.
- Don't present a changed copy as Broadway, or as made or endorsed by this project.

The icon is drawn by `Icon/icon.swift` when the app is built. That file is code like any other, under the MIT License. What a shipped fork should not do is present the same picture as its own app's icon, so people can tell the two apart.

The names of other companies' services that Broadway connects to, such as Claude and ChatGPT, are their owners' trademarks. See [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md).

Questions: support@broadwaybrowser.com.
