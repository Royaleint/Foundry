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
    },
}
