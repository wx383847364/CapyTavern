extends RefCounted
## 界面中文字体。系统默认中文字体（本机 PingFang SC）缺「敌」等字，会显示成带十六进制码的方框，
## 所以按顺序挑一个字全的系统字体；都没有时退回引擎默认。不引外部字体文件（美术资源区不归程序改）。
## 正式字体由美术在 client/assets/ 里给，到时这里换成加载它即可。

const NAMES := ["Heiti SC", "Hiragino Sans GB", "STHeiti", "Microsoft YaHei", "Noto Sans CJK SC", "PingFang SC"]

static var _font: Font = null


static func get_font() -> Font:
	if _font == null:
		var system := SystemFont.new()
		system.font_names = PackedStringArray(NAMES)
		_font = system
	return _font
