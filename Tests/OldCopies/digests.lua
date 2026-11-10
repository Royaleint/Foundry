-- Digests of the release sources, taken from the release tags (see digest.lua).
-- dump:   the compiled form of the tag's source, loaded as chunk '=pinned'.
-- source: the raw bytes of the tag's file (v1.0.114 copies are verbatim).
-- header: the first twelve bytes of a compiled chunk, in hex. They fix the build
-- layout (byte order, integer sizes) the compiled-form digests were taken on.
return {
    header = "1b4c75615100010408040800",
    copies = {
        ["v1.0.4"] = {
            ["Foundry.lua"] = { dump = "3029:0d19829e:be2ca8fa" },
            ["Modules/Commands.lua"] = { dump = "14969:fc15db64:6a076284" },
            ["Modules/Events.lua"] = { dump = "8418:976505da:486855bf" },
            ["Modules/Lifecycle.lua"] = { dump = "13204:ae401125:539e7414" },
            ["Modules/DB.lua"] = { dump = "24430:d4f1eaa4:4a13d1cd" },
        },
        ["v1.0.114"] = {
            ["Foundry.lua"] = { dump = "3536:e14929de:a4728696", source = "3738:6a988e8f:dcbd56ea" },
            ["Modules/Commands.lua"] = { dump = "20121:d35d91e5:6a30248c", source = "17701:006990f6:cefdb093" },
            ["Modules/Events.lua"] = { dump = "17713:6c5d502c:a09421b3", source = "15184:b27dc361:fc56d5ca" },
            ["Modules/Lifecycle.lua"] = { dump = "26197:0c686d8d:5944a18a", source = "23612:d55da13b:6876e315" },
            ["Modules/DB.lua"] = { dump = "33160:06529985:60674abc", source = "31754:a6ca28d4:aab5d146" },
            ["Modules/List.lua"] = { dump = "9830:99dc0c26:34adb790", source = "9487:728ec2cc:6eb0f8a4" },
            ["Modules/Settings.lua"] = { dump = "10898:91519511:235776cf", source = "12462:a8d84436:14cb8da9" },
            ["Modules/Tooltip.lua"] = { dump = "6543:d0661bd4:1f401e33", source = "8710:606a5236:6f479701" },
            ["Modules/Menu.lua"] = { dump = "4762:8bf1bdab:29ab9570", source = "5825:5c261338:01cb9df0" },
            ["Modules/Window.lua"] = { dump = "7970:3c7214fe:0713450c", source = "8072:20edca43:9f568991" },
        },
        -- Not a release: the ten files exactly as they stand at commit e6afff5,
        -- before any file carried a build number.
        layout1 = {
            ["Foundry.lua"] = { dump = "7239:3ba3ff22:97623dcc", source = "6551:58e520ee:be2dcf6e" },
            ["Modules/Commands.lua"] = { dump = "20806:ee95144b:e45ccb3d", source = "18198:6d1aa9ea:dc69c6c3" },
            ["Modules/Events.lua"] = { dump = "19457:ce542279:00837cbe", source = "16701:0eab097f:fe8b72b3" },
            ["Modules/Lifecycle.lua"] = { dump = "27239:41242c6e:562c9bf7", source = "24707:0784ee06:a80a762e" },
            ["Modules/DB.lua"] = { dump = "34085:405352e0:90530b82", source = "32667:dbb561e6:0d4ad59c" },
            ["Modules/List.lua"] = { dump = "10850:61fed46e:3b834eac", source = "10006:96e24499:10a227e5" },
            ["Modules/Settings.lua"] = { dump = "11381:1f2a0c37:91f7ad49", source = "12951:f5111a4d:63594898" },
            ["Modules/Tooltip.lua"] = { dump = "7171:fbe02458:6731435f", source = "8992:3e40bdc0:c23016bc" },
            ["Modules/Menu.lua"] = { dump = "5553:bc9ff66b:b36bd9e9", source = "6044:09d18339:c5a72f98" },
            ["Modules/Window.lua"] = { dump = "9066:1e9c3b67:6a3fd2ac", source = "8775:8163a309:d64e4efe" },
        },
    },
}
