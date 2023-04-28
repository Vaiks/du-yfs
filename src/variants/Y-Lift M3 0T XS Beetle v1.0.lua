local limited = require("variants/Limited").New()
limited.AddLimit(EngineType.ATMO, EngineSize.XS, 6)
limited.AddLimit(EngineType.ATMO, EngineSize.S, 2)
limited.AddLimit(EngineType.SPACE, EngineSize.XS, 10)
limited.Start()
