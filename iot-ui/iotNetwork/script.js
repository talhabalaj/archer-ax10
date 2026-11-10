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
            { name: "allowLan", mapping: "allow_lan", allowBlank: true }
        ],
        proxy: { url: $.su.url("/admin/iot_net?form=settings") }
    });

    $.su.storeManager.define("iotClientStore", {
        type: "store",
        fields: [{ name: "key" }, { name: "name" }, { name: "mac" }, { name: "ip" }, { name: "internet" }],
        proxy: { url: $.su.url("/admin/iot_net?form=clients") }
    });

    $.su.moduleManager.define("iotNetwork", {
        services: ["ajax"],
        models: ["iotNetworkModel"],
        stores: ["iotClientStore"],
        views: ["iotNetworkView"],
        listeners: {
            ev_on_launch: function (e, me, views, models, stores) {
                models.iotNetworkModel.load();
                stores.iotClientStore.load();
            }
        },
        init: function (me, views, models, stores) {
            this.configViews({
                id: "iotNetworkView",
                items: [{
                    id: "iot-client-grid",
                    configs: {
                        minLines: 0,
                        paging: {},
                        columns: [
                            { text: T.NAME, dataIndex: "name", width: "30%" },
                            { text: T.MAC, dataIndex: "mac", width: "25%" },
                            { text: T.IP, dataIndex: "ip", width: "25%" },
                            { text: T.INTERNET, dataIndex: "internet", xtype: "customWidget", widgetName: "switch",
                              settings: { trueValue: "on", falseValue: "off" }, width: "20%" }
                        ]
                    }
                }]
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
                    ev_grid_tbar_refresh: function () { stores.iotClientStore.load(); }
                }
            });
        }
    }, function () { return {}; });
})(jQuery);
