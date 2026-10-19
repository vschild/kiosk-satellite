# Plugin Manager

Plugin documentation lives in the [Community SDK repository](https://github.com/jxlarrea/kiosk-satellite-plugins).

- [Installing and managing plugins](https://github.com/jxlarrea/kiosk-satellite-plugins/blob/main/docs/installing-plugins.md): installation, settings, trust, updates and the remote API.
- [Creating plugins](https://github.com/jxlarrea/kiosk-satellite-plugins/blob/main/docs/creating-plugins.md): the SDK, lifecycle, package format, build tools and publishing.

Plugins can also use the optional [Shizuku connection](shizuku.md).

A fleet leader can install its plugins on its followers with their settings. See [Fleet Management](fleet.md#plugins).

## Browse plugins

**Settings > Plugin Manager > Browse plugins**, also in the remote admin, lists Community Plugins: plugins their authors submitted to the [plugins repository](https://github.com/jxlarrea/kiosk-satellite-plugins#submit-your-plugin). The same list is on [kiosksatellite.com](https://kiosksatellite.com/plugins/). Each plugin shows its icon, author, latest version, stars and downloads. Search narrows the list by name, description or author. **Sort by** orders it by Most downloads, Most stars, Recently updated, Newest or Name. **Plugins per page** picks 5, 10, 20, 50 or 100 plugins a page, 10 unless you change it.

Pick a plugin to see the same review that **Add plugin** shows, with its manifest and README, then choose **Trust and install**. A listed plugin you already have says **Installed**, or offers **Update** when the list knows a newer release. The review also says whether a repository is listed in Community Plugins.

The list refreshes twice a day on kiosksatellite.com. Kiosk Satellite downloads it when you open Browse plugins, at most once an hour, and keeps the last copy for when it is offline.

### Install from kiosksatellite.com

The **Install** button on a plugin's page on kiosksatellite.com asks for your kiosk's remote admin address the first time, such as `http://192.168.1.10:2324/`, and opens Plugin Manager there with the plugin's review. Remote admin must be on. Nothing installs until you choose **Trust and install**. If Enable Plugins is off, the remote admin asks to turn it on first.

The application retains its license with an [additional permission for independent plugins](../PLUGIN-EXCEPTION.md).
