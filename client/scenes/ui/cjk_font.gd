extends RefCounted
## 界面中文字体。原生端按顺序使用系统中文字体，网页端使用工程主题随包加载的字体。

const NAMES := ["Heiti SC", "Hiragino Sans GB", "STHeiti", "Microsoft YaHei", "Noto Sans CJK SC", "PingFang SC"]

static var _font: Font = null


## 为控件和手绘文字提供平台对应的中文字体。
static func get_font() -> Font:
	if OS.has_feature("web"):
		# Web 无法枚举系统字体，复用默认主题已加载的字体供 draw_string 使用。
		return ThemeDB.fallback_font
	if _font == null:
		var system := SystemFont.new()
		system.font_names = PackedStringArray(NAMES)
		_font = system
	return _font
