// Guest Speed page for the stock TP-Link web UI (Archer AX10): cap the speed of
// devices on the guest networks, with a per-device "Full speed" upgrade.
(function ($) {
    $.su.CHAR.GUEST_SPEED = $.su.CHAR.GUEST_SPEED || {};
    var T = $.su.CHAR.GUEST_SPEED, N = $.su.CHAR.IOT_NETWORK || {};

    $.su.modelManager.define("guestSpeedModel", {
        type: "model",
        fields: [
            { name: "enable" },
            { name: "down", allowBlank: false, vtype: { vtype: "number", min: "1", max: "1000" } },
            { name: "up", allowBlank: false, vtype: { vtype: "number", min: "1", max: "1000" } }
        ],
        proxy: { url: $.su.url("/admin/iot_net?form=guest_settings") }
    });

    $.su.storeManager.define("guestSpeedStore", {
        type: "store",
        fields: [{ name: "key" }, { name: "name" }, { name: "mac" }, { name: "ip" }, { name: "status" }, { name: "fast" }],
        proxy: { url: $.su.url("/admin/iot_net?form=guests") }
    });

    $.su.modelManager.define("guestSpeedEdit", {
        type: "model",
        fields: [{ name: "key" }, { name: "name", allowBlank: false, maxLength: 40 }, { name: "mac" },
                 { name: "ip" }, { name: "status" }, { name: "fast" }]
    });

    $.su.moduleManager.define("guestSpeed", {
        services: ["ajax"],
        models: ["guestSpeedModel", "guestSpeedEdit"],
        stores: ["guestSpeedStore"],
        views: ["guestSpeedView"],
        listeners: {
            ev_on_launch: function (e, me, views, models, stores) {
                models.guestSpeedModel.load();
                stores.guestSpeedStore.load();
            }
        },
        init: function (me, views, models, stores) {
            var store = stores.guestSpeedStore;
            this.configViews({
                id: "guestSpeedView",
                items: [{
                    id: "guest-speed-grid",
                    configs: {
                        minLines: 0,
                        paging: {},
                        popEditor: { editTitle: N.RENAME, content: "#guest-speed-edit", fields: [{ name: "name" }] },
                        columns: [
                            { text: N.NAME, dataIndex: "name", width: "26%" },
                            { text: N.MAC, dataIndex: "mac", width: "18%" },
                            { text: N.IP, dataIndex: "ip", width: "14%" },
                            { text: N.STATUS, dataIndex: "status", width: "22%" },
                            { text: T.FAST, dataIndex: "fast", xtype: "customWidget", widgetName: "switch",
                              settings: { trueValue: "on", falseValue: "off" }, width: "12%" },
                            { xtype: "actioncolumn", text: N.EDIT, width: "8%", renderer: function () {
                                return '<a href="javascript:void(0)" class="grid-content-btn grid-content-btn-edit btn-edit"><span class="icon"></span><span class="text"></span></a>';
                            } }
                        ]
                    }
                }]
            });
            this.control({
                "#guest-speed-grid": {
                    ev_grid_tbar_refresh: function () { store.load(); },
                    // Save each switch immediately: a store sync sends only one changed row.
                    ev_grid_custom_change: function (e, change, widget, rowKey) {
                        if (!change || change.type !== "value") return;
                        try {
                            var m = store.getModelByKey(rowKey), f = m && m.getField("fast");
                            if (f && f.getValue() !== change.value) f.setValue(change.value);
                        } catch (err) { /* the cell binding already updated the row */ }
                        setTimeout(function () { store.sync(); }, 0);
                    },
                    ev_grid_save: function () { setTimeout(function () { store.sync(); }, 0); }
                }
            });
        }
    }, function () { return {}; });
})(jQuery);
