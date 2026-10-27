"""Render documentation mockups using fictional data only; not device screenshots."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / 'docs' / 'images'
FONT = Path('C:/Windows/Fonts/msyh.ttc')
if not FONT.exists():
    FONT = Path('/usr/share/fonts/truetype/wqy/wqy-microhei.ttc')
BG, CARD, INK, MUTED, ACCENT = '#11121B', '#1E202D', '#F5F3F1', '#9294A5', '#FFBC62'

def render(name, title, subtitle, rows, mini=False):
    image = Image.new('RGB', (780, 1400), BG)
    d = ImageDraw.Draw(image)
    def text(x, y, value, size=26, color=INK):
        d.text((x, y), value, font=ImageFont.truetype(str(FONT), size), fill=color)
    text(40, 24, '9:41', 22)
    text(520, 24, '模拟数据 · 示意图', 20, MUTED)
    text(40, 110, title, 52)
    text(40, 190, subtitle, 23, MUTED)
    y = 270
    for heading, detail in rows:
        d.rounded_rectangle((32, y, 748, y + 155), radius=24, fill=CARD, outline='#353847', width=2)
        text(54, y + 24, heading, 30)
        text(54, y + 85, detail, 22, MUTED)
        y += 180
    if mini:
        d.rounded_rectangle((26, 1110, 754, 1220), radius=22, fill=CARD, outline='#68D8B0', width=2)
        text(50, 1125, '森林漫步 · 示例影片', 25)
        text(50, 1172, '03:20 / 12:00                 暂停    ×', 20, MUTED)
        d.rounded_rectangle((50, 1201, 710, 1205), radius=2, fill='#353847')
        d.rounded_rectangle((50, 1201, 230, 1205), radius=2, fill=ACCENT)
    d.rounded_rectangle((60, 1260, 720, 1348), radius=44, fill=CARD, outline='#353847', width=2)
    text(100, 1284, 'Y       T       D       废纸篓', 30, ACCENT)
    text(40, 1370, '界面示意：虚构内容，不代表真机测试结果', 18, MUTED)
    image.save(OUT / name)

render('library.jpg', '油管', '3 部示例影片 · 长按拖动排序', [
    ('森林漫步', '自然影像 · 12:00 · 离线可用'),
    ('认识星空', '科学课堂 · 08:30 · 离线可用'),
    ('城市的一天', '旅行笔记 · 06:15 · 离线可用')], mini=True)
render('telegram-library.jpg', '飞机', '群组/频道    已下载        锁定    设置    +', [
    ('公开课程 · 示例频道', '虚构频道 · 无真实会话'),
    ('旅行记录 · 示例群组', '虚构群组 · 下拉刷新'),
    ('已下载：山间清晨', '示例视频 · 05:20 · 离线可用')])
render('downloads.jpg', '正在下载', '暂停    并发 2 个    删除', [
    ('森林漫步', '下载中 42% · 2.4 MB/s'),
    ('认识星空', '排队中 · 第 1 位'),
    ('城市的一天', '排队中 · 第 2 位')])
render('trash.jpg', '废纸篓', '不可播放 · 右滑恢复 · 左滑彻底删除', [
    ('森林漫步', '6 天后删除 · 虚构影片'),
    ('认识星空', '5 天后删除 · 虚构影片'),
    ('城市的一天', '3 天后删除 · 虚构影片')])
render('settings.png', '设置', '页面顶部标题 · 修改后立即生效', [
    ('YouTube 标题           恢复默认', '油管'),
    ('Telegram 标题          恢复默认', '飞机'),
    ('下载画质', '480p 省空间'),
    ('播放速度', '0.5×   1×   1.5×   2×')])
render('downloads-controls.png', '下载操作区', '模拟数据 · 操作按钮示意', [
    ('暂停 / 继续', '暂停全部任务，再次点击继续'),
    ('并发数量', '选择同时下载 1–4 个任务'),
    ('全部删除', '确认后删除任务，不影响已下载影片')])
render('paste-permission.jpg', '剪贴板导入', '模拟提示 · 非系统真实截图', [
    ('允许“拾影”粘贴？', '允许粘贴 / 不允许粘贴'),
    ('可在设置关闭自动读取', '也可在添加页面手动粘贴链接')])
print('Rendered 7 fictional documentation mockups.')
