// IoT Network page for the stock TP-Link web UI (Archer AX10), written against the
// stock $.su framework the same way the built-in pages are.
(function ($) {
    // Labels are added to the locale file by `iot.sh ui` (iot-ui/locale.js).
    $.su.CHAR.IOT_NETWORK = $.su.CHAR.IOT_NETWORK || {};
    var T = $.su.CHAR.IOT_NETWORK;

    $.su.modelManager.define("iotNetworkModel", {
        type: "model",
        fields: [
            { name: "enable" },
            { name: "ssid", allowBlank: false, minLength: 1, maxLength: 32 },
            { name: "hidden" },
            { name: "password", allowBlank: false, vtype: "psk_password" },
            { name: "gateway" },
            { name: "allowLan", mapping: "allow_lan", allowBlank: true },
            { name: "lanMode", mapping: "lan_mode", defaultValue: "all" }
        ],
        proxy: { url: $.su.url("/admin/iot_net?form=settings") }
    });

    $.su.storeManager.define("iotClientStore", {
        type: "store",
        fields: [{ name: "key" }, { name: "name" }, { name: "mac" }, { name: "ip" }, { name: "internet" }],
        proxy: { url: $.su.url("/admin/iot_net?form=clients") }
    });

    $.su.storeManager.define("iotHomeStore", {
        type: "store",
        fields: [{ name: "key" }, { name: "name" }, { name: "mac" }, { name: "ip" }, { name: "allowed" }],
        proxy: { url: $.su.url("/admin/iot_net?form=homes") }
    });

    // A store's sync sends only the first changed row (key/new/old), so save each
    // switch the moment it is flipped instead of waiting for the page's Save button.
    function saveOnFlip(store, field) {
        return function (e, change, widget, rowKey) {
            if (!change || change.type !== "value") return;
            try {
                var m = store.getModelByKey(rowKey), f = m && m.getField(field);
                if (f && f.getValue() !== change.value) f.setValue(change.value);
            } catch (err) { /* the cell binding already updated the row */ }
            setTimeout(function () { store.sync(); }, 0);
        };
    }

    function switchColumn(text, dataIndex) {
        return { text: text, dataIndex: dataIndex, xtype: "customWidget", widgetName: "switch",
                 settings: { trueValue: "on", falseValue: "off" }, width: "20%" };
    }

    $.su.moduleManager.define("iotNetwork", {
        services: ["ajax"],
        models: ["iotNetworkModel"],
        stores: ["iotClientStore", "iotHomeStore"],
        views: ["iotNetworkView"],
        listeners: {
            ev_on_launch: function (e, me, views, models, stores) {
                models.iotNetworkModel.load();
                stores.iotClientStore.load();
                stores.iotHomeStore.load();
            }
        },
        init: function (me, views, models, stores) {
            var columns = function (last) {
                return [
                    { text: T.NAME, dataIndex: "name", width: "30%" },
                    { text: T.MAC, dataIndex: "mac", width: "25%" },
                    { text: T.IP, dataIndex: "ip", width: "25%" },
                    last
                ];
            };
            this.configViews({
                id: "iotNetworkView",
                items: [
                    { id: "iot-client-grid", configs: { minLines: 0, paging: {}, columns: columns(switchColumn(T.INTERNET, "internet")) } },
                    { id: "iot-home-grid", configs: { minLines: 0, paging: {}, columns: columns(switchColumn(T.ALLOW, "allowed")) } }
                ]
            });
            this.listen({
                "models.iotNetworkModel.enable": {
                    ev_value_change: function (e, value) {
                        var f = views.iotNetworkView.iotNetworkFields;
                        if (!f) return;
                        value === "on" ? f.enable() : f.disable();
                    }
                }
            });
            this.control({
                "#iot-client-grid": {
                    ev_grid_tbar_refresh: function () { stores.iotClientStore.load(); },
                    ev_grid_custom_change: saveOnFlip(stores.iotClientStore, "internet")
                },
                "#iot-home-grid": {
                    ev_grid_tbar_refresh: function () { stores.iotHomeStore.load(); },
                    ev_grid_custom_change: saveOnFlip(stores.iotHomeStore, "allowed")
                }
            });
        }
    }, function () { return {}; });
})(jQuery);
