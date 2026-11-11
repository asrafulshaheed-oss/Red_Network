#:package SkiaSharp@3.116.1
#:package SkiaSharp.NativeAssets.Linux@3.116.1

using System;
using System.IO;
using System.Diagnostics;
using System.Collections.Generic;
using System.Net.Http;
using SkiaSharp;

class Program
{
    const int W = 1672, H = 941;
    const int FPS = 30;
    const int DURATION_SEC = 2;
    static int TotalFrames => FPS * DURATION_SEC;

    public static Random rnd = new Random(666);
    public static float Rf(float a, float b) => a + (float)rnd.NextDouble() * (b - a);
    public static int Cl(double v) => (int)Math.Clamp(v, 0, 255);
    public static SKColor Col(int r, int g, int b, int a = 255) => new SKColor((byte)Cl(r), (byte)Cl(g), (byte)Cl(b), (byte)Cl(a));

    static void Main()
    {
        Console.WriteLine("Pre-generating scene data...");
        var scene = new SceneData();
        scene.Generate();

        var frames = new List<string>();
        Console.WriteLine("Rendering frames...");
        for (int i = 0; i < TotalFrames; i++)
        {
            float time = i / (float)FPS;
            using var surface = SKSurface.Create(new SKImageInfo(W, H));
            var c = surface.Canvas;
            RenderFrame(c, time, scene);
            using var img = surface.Snapshot();
            // Use JPEG for smaller file size while maintaining quality
            using var data = img.Encode(SKEncodedImageFormat.Jpeg, 85); 
            frames.Add(Convert.ToBase64String(data.ToArray()));
            Console.Write($"\rRendered frame {i + 1}/{TotalFrames}");
        }
        Console.WriteLine("\nGenerating HTML...");

        string html = $@"
<!DOCTYPE html>
<html>
<head>
<meta charset='UTF-8'>
<meta name='viewport' content='width=device-width, initial-scale=1'>
<title>BossDefender - Hellfire Animated</title>
<style>
    body {{ margin: 0; background: #000; display: flex; justify-content: center; align-items: center; height: 100vh; overflow: hidden; }}
    img {{ max-width: 100%; max-height: 100%; box-shadow: 0 0 50px rgba(255, 0, 0, 0.2); }}
</style>
</head>
<body>
<img id='anim' src='data:image/jpeg;base64,{frames[0]}' />
<script>
const frames = [
{string.Join(",\n", frames.ConvertAll(f => $"'{f}'"))}
];
let i = 0;
setInterval(() => {{
    i = (i + 1) % frames.length;
    document.getElementById('anim').src = frames[i];
}}, {1000 / FPS});
</script>
</body>
</html>";

        string htmlPath = Path.Combine(Path.GetTempPath(), "BossDefender_Animated.html");
        File.WriteAllText(htmlPath, html);

        Console.WriteLine("Launching animation in browser...");
        try
        {
            if (OperatingSystem.IsWindows())
                Process.Start(new ProcessStartInfo(htmlPath) { UseShellExecute = true });
            else if (OperatingSystem.IsMacOS())
                Process.Start("open", htmlPath);
            else
                Process.Start("xdg-open", htmlPath);
        }
        catch { Console.WriteLine("Could not open browser automatically. Open manually: " + htmlPath); }
    }

    static void RenderFrame(SKCanvas c, float time, SceneData scene)
    {
        // 1. Background
        c.Clear(Col(6, 0, 0));
        using (var p = new SKPaint
        {
            Shader = SKShader.CreateRadialGradient(new SKPoint(W * .5f, H * .42f), W * .75f,
                new[] { Col(78, 5, 3), Col(34, 1, 1), Col(4, 0, 0) }, new[] { 0f, .5f, 1f }, SKShaderTileMode.Clamp)
        })
            c.DrawRect(0, 0, W, H, p);

        // Vertical streaks
        for (int i = 0; i < 260; i++)
        {
            float x = Rf(0, W), y0 = Rf(0, H * .3f), y1 = y0 + Rf(120, H);
            bool red = rnd.NextDouble() < .35;
            using var sp = new SKPaint
            {
                Color = red ? Col(150, 12, 6, 24) : Col(0, 0, 0, (int)Rf(40, 100)),
                StrokeWidth = Rf(1, 3.2f), IsAntialias = true
            };
            c.DrawLine(x, y0, x, y1, sp);
        }

        // Animated Fog & Hell-fire
        NoiseLayer(c, .0040f, .0050f, 5, 3, scene.FogRamp, scene.RadialMaskCenter, SKBlendMode.Plus, true, time, 10, 5);
        NoiseLayer(c, .0060f, .0045f, 5, 9, scene.FogRamp, scene.RadialMaskLeft, SKBlendMode.Plus, true, time, 15, -5);

        NoiseLayer(c, .012f, .0055f, 5, 21, scene.FireRamp, scene.VMaskBottom, SKBlendMode.Plus, false, time, 20, -15);
        NoiseLayer(c, .010f, .0050f, 5, 44, scene.FireRamp, scene.RadialMaskFireLeft, SKBlendMode.Plus, false, time, 25, -20);
        NoiseLayer(c, .010f, .0050f, 5, 77, scene.FireRamp, scene.RadialMaskFireRight, SKBlendMode.Plus, false, time, 30, -10);

        // 2. Moon, Graveyard & Chains
        DrawMoon(c, time, scene);
        DrawGraveyard(c);
        DrawChains(c);

        // 3. Main Skull & Fire
        DrawSkull(c, 830, 270, 1.0f, 0, true, 7, time);
        DrawFlames(c, time, scene.Flames);

        // 4. Bottom Skulls
        DrawBottomSkulls(c);

        // 5. Typography (with animated drips)
        DrawText(c, scene, time);

        // 6. Embers
        DrawEmbers(c, time, scene.Embers);

        // 7. Vignette & Grain
        using (var vg = new SKPaint
        {
            Shader = SKShader.CreateRadialGradient(new SKPoint(W / 2f, H / 2f), W * .62f,
                new[] { Col(0, 0, 0, 0), Col(0, 0, 0, 40), Col(0, 0, 0, 215) }, new[] { 0f, .62f, 1f }, SKShaderTileMode.Clamp)
        })
            c.DrawRect(0, 0, W, H, vg);

        using (var gr = new SKPaint
        {
            Shader = SKShader.CreatePerlinNoiseFractalNoise(.9f, .9f, 2, 99),
            ColorFilter = scene.GrayRamp, BlendMode = SKBlendMode.SoftLight, Color = Col(255, 255, 255, 60)
        })
            c.DrawRect(0, 0, W, H, gr);
    }

    static void NoiseLayer(SKCanvas c, float fx, float fy, int oct, float seed, SKColorFilter ramp, SKShader mask, SKBlendMode blend, bool fractal = false, float time = 0, float speedX = 0, float speedY = 0)
    {
        using var layerPaint = new SKPaint { BlendMode = blend };
        c.SaveLayer(layerPaint);
        using var np = new SKPaint
        {
            Shader = fractal
                ? SKShader.CreatePerlinNoiseFractalNoise(fx, fy, oct, seed)
                : SKShader.CreatePerlinNoiseTurbulence(fx, fy, oct, seed),
            ColorFilter = ramp
        };
        c.Save();
        if (speedX != 0 || speedY != 0) c.Translate(time * speedX, time * speedY);
        c.DrawRect(-W, -H, W * 3, H * 3, np);
        c.Restore();
        using var mp = new SKPaint { Shader = mask, BlendMode = SKBlendMode.DstIn };
        c.DrawRect(0, 0, W, H, mp);
        c.Restore();
    }

    static void Glow(SKCanvas c, SKPath path, SKColor color, float sigma)
    {
        using var p = new SKPaint
        {
            Color = color, IsAntialias = true,
            BlendMode = SKBlendMode.Plus,
            MaskFilter = SKMaskFilter.CreateBlur(SKBlurStyle.Normal, sigma)
        };
        c.DrawPath(path, p);
    }

    static void DrawMoon(SKCanvas c, float time, SceneData scene)
    {
        var moonC = new SKPoint(1440, 205); const float moonR = 100;
        using (var mg = new SKPaint
        {
            BlendMode = SKBlendMode.Plus,
            Shader = SKShader.CreateRadialGradient(moonC, 300,
                new[] { Col(255, 70, 25, 150), Col(160, 20, 8, 60), Col(0, 0, 0, 0) }, new[] { 0f, .4f, 1f }, SKShaderTileMode.Clamp)
        })
            c.DrawCircle(moonC, 300, mg);

        c.Save();
        using (var clip = new SKPath()) { clip.AddCircle(moonC.X, moonC.Y, moonR); c.ClipPath(clip, SKClipOperation.Intersect, true); }
        using (var mp = new SKPaint
        {
            Shader = SKShader.CreateRadialGradient(new SKPoint(moonC.X - 25, moonC.Y - 20), moonR * 1.3f,
                new[] { Col(255, 120, 55), Col(205, 50, 22), Col(120, 12, 8) }, new[] { 0f, .55f, 1f }, SKShaderTileMode.Clamp)
        })
            c.DrawCircle(moonC, moonR, mp);
        
        c.Save();
        c.Translate(MathF.Sin(time) * 5, MathF.Cos(time) * 5);
        using (var np = new SKPaint
        {
            Shader = SKShader.CreatePerlinNoiseFractalNoise(.03f, .03f, 5, 12),
            ColorFilter = scene.MoonRamp, Color = Col(255, 255, 255, 120), BlendMode = SKBlendMode.Multiply
        })
            c.DrawRect(moonC.X - moonR - 10, moonC.Y - moonR - 10, moonR * 2 + 20, moonR * 2 + 20, np);
        c.Restore();

        for (int i = 0; i < 26; i++)
        {
            float a = Rf(0, 6.28f), d = Rf(0, moonR * .9f), rr = Rf(4, 17);
            using var cp = new SKPaint
            {
                Color = Col(70, 5, 3, (int)Rf(40, 90)), IsAntialias = true,
                MaskFilter = SKMaskFilter.CreateBlur(SKBlurStyle.Normal, rr * .35f)
            };
            c.DrawCircle(moonC.X + MathF.Cos(a) * d, moonC.Y + MathF.Sin(a) * d, rr, cp);
        }
        using (var edge = new SKPaint
        {
            Shader = SKShader.CreateRadialGradient(moonC, moonR,
                new[] { Col(0, 0, 0, 0), Col(0, 0, 0, 0), Col(40, 0, 0, 160) }, new[] { 0f, .72f, 1f }, SKShaderTileMode.Clamp)
        })
            c.DrawCircle(moonC, moonR, edge);
        c.Restore();
    }

    static void DrawGraveyard(SKCanvas c)
    {
        void Cross(float x, float y, float h, float tilt, int alpha)
        {
            c.Save(); c.Translate(x, y); c.RotateDegrees(tilt);
            var p = new SKPath();
            float w = h * .075f;
            p.AddRect(new SKRect(-w / 2, 0, w / 2, h));
            p.AddRect(new SKRect(-h * .27f, h * .22f, h * .27f, h * .22f + w));
            Glow(c, p, Col(255, 40, 15, 90), 8);
            using var fp = new SKPaint { Color = Col(18, 1, 1, alpha), IsAntialias = true };
            c.DrawPath(p, fp);
            c.Restore();
        }

        float[][] graves = {
            new[]{1335f,372f,34f,92f}, new[]{1380f,350f,40f,120f}, new[]{1545f,300f,26f,130f},
            new[]{1560f,380f,50f,90f}, new[]{1510f,400f,44f,100f}, new[]{1600f,420f,60f,110f},
            new[]{1290f,430f,30f,70f}, new[]{1175f,390f,24f,90f}, new[]{1090f,430f,30f,60f}
        };
        foreach (var g in graves)
        {
            var r = new SKRect(g[0], g[1], g[0] + g[2], g[1] + g[3]);
            var p = new SKPath(); p.AddRoundRect(r, g[2] * .35f, g[2] * .2f);
            Glow(c, p, Col(200, 25, 10, 55), 10);
            using var fp = new SKPaint { Color = Col(16, 1, 1, 215), IsAntialias = true };
            c.DrawPath(p, fp);
        }
        Cross(1470, 240, 170, -4, 235);
        Cross(1555, 285, 95, 7, 220);
        Cross(1325, 355, 80, -9, 200);
        Cross(1200, 395, 60, 5, 180);
        Cross(1010, 420, 50, -6, 160);
        Cross(472, 822, 52, 4, 235);
    }

    static void DrawChains(SKCanvas c)
    {
        void Chain(SKPoint p0, SKPoint p1, SKPoint p2, SKPoint p3, float linkLen, float linkW, float stroke, int alpha)
        {
            var pts = new List<SKPoint>();
            for (int i = 0; i <= 500; i++)
            {
                float t = i / 500f, u = 1 - t;
                pts.Add(new SKPoint(
                    u * u * u * p0.X + 3 * u * u * t * p1.X + 3 * u * t * t * p2.X + t * t * t * p3.X,
                    u * u * u * p0.Y + 3 * u * u * t * p1.Y + 3 * u * t * t * p2.Y + t * t * t * p3.Y));
            }
            float acc = 0, next = 0; int idx = 0;
            for (int i = 1; i < pts.Count; i++)
            {
                float dx = pts[i].X - pts[i - 1].X, dy = pts[i].Y - pts[i - 1].Y;
                acc += MathF.Sqrt(dx * dx + dy * dy);
                if (acc < next) continue;
                next += linkLen;
                float ang = MathF.Atan2(dy, dx) * 180f / MathF.PI;
                c.Save(); c.Translate(pts[i].X, pts[i].Y); c.RotateDegrees(ang);
                using var paint = new SKPaint
                {
                    IsAntialias = true, Color = Col(255, 255, 255, alpha),
                    Shader = SKShader.CreateLinearGradient(new SKPoint(0, -linkW / 2), new SKPoint(0, linkW / 2),
                        new[] { Col(135, 24, 16), Col(52, 6, 4), Col(8, 0, 0) }, new[] { 0f, .5f, 1f }, SKShaderTileMode.Clamp)
                };
                if (idx % 2 == 0)
                {
                    paint.Style = SKPaintStyle.Stroke; paint.StrokeWidth = stroke;
                    var rr = new SKRoundRect(new SKRect(-linkLen * .62f, -linkW / 2, linkLen * .62f, linkW / 2), linkW / 2, linkW / 2);
                    using var sh = new SKPaint { IsAntialias = true, Style = SKPaintStyle.Stroke, StrokeWidth = stroke + 3, Color = Col(0, 0, 0, alpha / 2) };
                    c.DrawRoundRect(rr, sh);
                    c.DrawRoundRect(rr, paint);
                }
                else
                {
                    var rr = new SKRoundRect(new SKRect(-linkLen * .6f, -stroke * .6f, linkLen * .6f, stroke * .6f), stroke * .6f, stroke * .6f);
                    using var sh = new SKPaint { IsAntialias = true, Color = Col(0, 0, 0, alpha / 2) };
                    c.DrawRoundRect(new SKRoundRect(new SKRect(-linkLen * .6f - 1, -stroke * .6f - 1.5f, linkLen * .6f + 1, stroke * .6f + 1.5f), stroke, stroke), sh);
                    paint.Style = SKPaintStyle.Fill;
                    c.DrawRoundRect(rr, paint);
                }
                c.Restore(); idx++;
            }
        }

        Chain(new(25, -20), new(-10, 200), new(60, 380), new(175, 575), 34, 24, 7, 225);
        Chain(new(500, 105), new(380, 210), new(200, 240), new(-20, 310), 30, 21, 6, 190);
        Chain(new(1390, -10), new(1280, 30), new(1160, 70), new(1095, 150), 30, 21, 6, 175);
        Chain(new(1690, 280), new(1640, 420), new(1580, 540), new(1500, 650), 38, 27, 8, 215);
        Chain(new(1700, 560), new(1620, 650), new(1470, 750), new(1320, 840), 40, 29, 8, 225);
    }

    static void DrawSkull(SKCanvas c, float cx, float cy, float s, float rot, bool fiery, int seed, float time)
    {
        var lr = new Random(seed);
        float L(float a, float b) => a + (float)lr.NextDouble() * (b - a);
        c.Save(); c.Translate(cx, cy); c.RotateDegrees(rot); c.Scale(s, s);

        var sil = SKPath.ParseSvgPathData(
            "M0,-185 C85,-185 142,-125 139,-48 C138,-8 122,16 113,42 C106,66 96,84 86,100 L78,128 C74,142 66,150 56,154 " +
            "L40,168 C20,172 -20,172 -40,168 L-56,154 C-66,150 -74,142 -78,128 L-86,100 C-96,84 -106,66 -113,42 " +
            "C-122,16 -138,-8 -139,-48 C-142,-125 -85,-185 0,-185 Z");

        using (var fp = new SKPaint
        {
            IsAntialias = true,
            Shader = SKShader.CreateLinearGradient(new SKPoint(0, -185), new SKPoint(0, 170),
                new[] { Col(176, 82, 52), Col(104, 34, 22), Col(52, 10, 8), Col(18, 2, 2) }, new[] { 0f, .35f, .7f, 1f }, SKShaderTileMode.Clamp)
        })
            c.DrawPath(sil, fp);

        c.Save();
        c.ClipPath(sil, SKClipOperation.Intersect, true);

        using (var np = new SKPaint
        {
            Shader = SKShader.CreatePerlinNoiseTurbulence(.045f, .05f, 4, seed % 50 + 1),
            ColorFilter = new SceneData().SkinRamp, BlendMode = SKBlendMode.Multiply
        })
            c.DrawRect(-200, -200, 400, 420, np);

        foreach (var (hx, hy, hw, hh) in new[] { (-118f, -10f, 34f, 70f), (118f, -10f, 34f, 70f), (-92f, 70f, 26f, 40f), (92f, 70f, 26f, 40f) })
        {
            using var hp = new SKPaint { Color = Col(8, 0, 0, 150), IsAntialias = true, MaskFilter = SKMaskFilter.CreateBlur(SKBlurStyle.Normal, 16) };
            c.DrawOval(hx, hy, hw, hh, hp);
        }
        
        if (fiery)
        {
            using var hl = new SKPaint
            {
                BlendMode = SKBlendMode.Plus,
                Shader = SKShader.CreateRadialGradient(new SKPoint(0, -140), 130,
                    new[] { Col(255, 150, 60, 150), Col(255, 70, 20, 50), Col(0, 0, 0, 0) }, new[] { 0f, .5f, 1f }, SKShaderTileMode.Clamp)
            };
            c.DrawCircle(0, -140, 130, hl);
        }

        for (int i = 0; i < 22; i++)
        {
            var cp = new SKPath();
            float x = L(-120, 120), y = L(-170, 60);
            cp.MoveTo(x, y);
            int segs = lr.Next(4, 9);
            for (int k = 0; k < segs; k++) { x += L(-14, 14); y += L(2, 16); cp.LineTo(x, y); }
            using var kp = new SKPaint { Style = SKPaintStyle.Stroke, StrokeWidth = L(.7f, 1.7f), Color = Col(22, 2, 2, (int)L(130, 210)), IsAntialias = true };
            c.DrawPath(cp, kp);
        }
        c.Restore();

        for (int side = -1; side <= 1; side += 2)
        {
            c.Save(); c.Scale(side, 1);
            var sock = SKPath.ParseSvgPathData("M-108,-46 C-82,-64 -40,-44 -16,-14 C-18,10 -42,30 -72,26 C-102,18 -114,-14 -108,-46 Z");
            using (var sp = new SKPaint
            {
                IsAntialias = true,
                Shader = SKShader.CreateLinearGradient(new SKPoint(0, -60), new SKPoint(0, 30),
                    new[] { Col(2, 0, 0), Col(26, 2, 2) }, null, SKShaderTileMode.Clamp)
            })
                c.DrawPath(sock, sp);

            if (fiery)
            {
                c.Save(); c.ClipPath(sock, SKClipOperation.Intersect, true);
                c.Save(); c.Translate(-58, -6); c.RotateDegrees(18);
                using (var ep = new SKPaint
                {
                    IsAntialias = true, BlendMode = SKBlendMode.Plus,
                    Shader = SKShader.CreateRadialGradient(new SKPoint(0, 0), 30,
                        new[] { Col(255, 170, 70), Col(255, 60, 20), Col(140, 0, 0, 200), Col(0, 0, 0, 0) }, new[] { 0f, .3f, .7f, 1f }, SKShaderTileMode.Clamp)
                })
                    c.DrawOval(0, 0, 30, 13, ep);
                c.Restore(); c.Restore();

                c.Save(); c.Translate(-58, -6); c.RotateDegrees(18);
                float pulse = MathF.Sin(time * 8) * 0.2f + 0.8f; // Pulsing glow
                using var gp = new SKPaint
                {
                    IsAntialias = true, BlendMode = SKBlendMode.Plus, Color = Col(255, 50, 15, (int)(150 * pulse)),
                    MaskFilter = SKMaskFilter.CreateBlur(SKBlurStyle.Normal, 9)
                };
                c.DrawOval(0, 0, 26 * pulse, 10 * pulse, gp);
                c.Restore();
            }
            using (var bp = new SKPaint { Style = SKPaintStyle.Stroke, StrokeWidth = 3, IsAntialias = true, Color = Col(255, 140, 70, fiery ? 110 : 40), MaskFilter = SKMaskFilter.CreateBlur(SKBlurStyle.Normal, 1.5f) })
                c.DrawPath(SKPath.ParseSvgPathData("M-112,-52 C-84,-72 -38,-50 -12,-18"), bp);
            c.Restore();
        }

        using (var np = new SKPaint { Color = Col(6, 0, 0), IsAntialias = true })
            c.DrawPath(SKPath.ParseSvgPathData("M0,36 C-12,52 -26,78 -15,93 C-9,98 -3,90 0,86 C3,90 9,98 15,93 C26,78 12,52 0,36 Z"), np);

        using (var mp = new SKPaint { Color = Col(5, 0, 0), IsAntialias = true })
            c.DrawPath(SKPath.ParseSvgPathData("M-62,106 L62,106 L58,160 L-58,160 Z"), mp);
        for (int row = 0; row < 2; row++)
        {
            int n = row == 0 ? 9 : 8;
            float y0 = row == 0 ? 108 : 138, h = row == 0 ? 26 : 22;
            float x0 = row == 0 ? -58 : -52;
            for (int i = 0; i < n; i++)
            {
                float x = x0 + i * 13.2f + L(-.5f, .5f), hh = h + L(-3, 3);
                var tr = new SKRoundRect(new SKRect(x, y0, x + 11.5f, y0 + hh), 3, 3);
                using var tp = new SKPaint
                {
                    IsAntialias = true,
                    Shader = SKShader.CreateLinearGradient(new SKPoint(0, y0), new SKPoint(0, y0 + hh),
                        new[] { Col(196, 140, 108), Col(112, 62, 44), Col(50, 18, 12) }, null, SKShaderTileMode.Clamp)
                };
                using var op = new SKPaint { IsAntialias = true, Style = SKPaintStyle.Stroke, StrokeWidth = 1.4f, Color = Col(12, 0, 0, 220) };
                c.DrawRoundRect(tr, tp); c.DrawRoundRect(tr, op);
            }
        }

        if (fiery)
        {
            using var rim = new SKPaint
            {
                Style = SKPaintStyle.Stroke, StrokeWidth = 6, IsAntialias = true, BlendMode = SKBlendMode.Plus,
                Color = Col(255, 120, 35, 150), MaskFilter = SKMaskFilter.CreateBlur(SKBlurStyle.Normal, 5)
            };
            c.DrawPath(sil, rim);
        }
        using (var edge = new SKPaint { Style = SKPaintStyle.Stroke, StrokeWidth = 2, IsAntialias = true, Color = Col(10, 0, 0, 200) })
            c.DrawPath(sil, edge);

        c.Restore();
    }

    static void DrawFlames(SKCanvas c, float time, List<Flame> flames)
    {
        foreach (var f in flames)
        {
            // Animate the tip of the flame using sine waves
            float wobble = MathF.Sin(time * 8 + f.Phase) * 15;
            float tx = f.Tx + wobble;
            float ty = f.Ty + MathF.Cos(time * 6 + f.Phase) * 10;
            
            var p = new SKPath();
            p.MoveTo(f.Bx - f.Wd / 2, f.By);
            p.QuadTo(f.Bx - f.Wd * .9f + (tx - f.Bx) * .3f, f.By + (ty - f.By) * .5f, tx, ty);
            p.QuadTo(f.Bx + f.Wd * .9f + (tx - f.Bx) * .3f, f.By + (ty - f.By) * .5f, f.Bx + f.Wd / 2, f.By);
            p.Close();
            
            using var fp = new SKPaint
            {
                IsAntialias = true, BlendMode = SKBlendMode.Plus,
                MaskFilter = SKMaskFilter.CreateBlur(SKBlurStyle.Normal, 4),
                Shader = SKShader.CreateLinearGradient(new SKPoint(f.Bx, f.By), new SKPoint(tx, ty),
                    new[] { Col(255, 200, 110, 150), Col(255, 90, 20, 105), Col(180, 20, 5, 0) }, new[] { 0f, .5f, 1f }, SKShaderTileMode.Clamp)
            };
            c.DrawPath(p, fp);
        }
    }

    static void DrawBottomSkulls(SKCanvas c)
    {
        void DarkSkull(float x, float y, float s, float rot, int seed)
        {
            using var lp = new SKPaint
            {
                ColorFilter = SKColorFilter.CreateColorMatrix(new float[]
                {
                    .62f, 0, 0, 0, 0,
                    0, .30f, 0, 0, 0,
                    0, 0, .26f, 0, 0,
                    0, 0, 0, 1, 0
                })
            };
            c.SaveLayer(lp);
            DrawSkull(c, x, y, s, rot, false, seed, 0);
            c.Restore();
            using var fire = new SKPaint
            {
                BlendMode = SKBlendMode.Plus,
                Shader = SKShader.CreateRadialGradient(new SKPoint(x, y + 160 * s), 220 * s,
                    new[] { Col(255, 90, 25, 90), Col(140, 20, 8, 40), Col(0, 0, 0, 0) }, new[] { 0f, .5f, 1f }, SKShaderTileMode.Clamp)
            };
            c.DrawCircle(x, y + 160 * s, 220 * s, fire);
        }
        DarkSkull(105, 865, 1.0f, 8, 11);
        DarkSkull(1585, 830, 0.95f, -9, 23);
        DarkSkull(1400, 955, 0.8f, 14, 35);
        DarkSkull(300, 965, 0.55f, -20, 41);
    }

    static void DrawText(SKCanvas c, SceneData scene, float time)
    {
        var tBoss = scene.TextBoss;
        var tLock = scene.TextLock;

        Glow(c, tBoss, Col(255, 25, 8, 170), 26);
        Glow(c, tBoss, Col(255, 60, 20, 90), 8);
        Glow(c, tLock, Col(255, 40, 20, 90), 12);

        using (var ol = new SKPaint { IsAntialias = true, Style = SKPaintStyle.Stroke, StrokeWidth = 7, StrokeJoin = SKStrokeJoin.Round, Color = Col(18, 0, 0) })
        {
            c.DrawPath(tBoss, ol);
            ol.StrokeWidth = 5;
            c.DrawPath(tLock, ol);
        }

        var bb = tBoss.Bounds;
        using (var fp = new SKPaint
        {
            IsAntialias = true,
            Shader = SKShader.CreateLinearGradient(new SKPoint(0, bb.Top), new SKPoint(0, bb.Bottom),
                new[] { Col(238, 38, 30), Col(185, 12, 14), Col(108, 0, 6) }, new[] { 0f, .5f, 1f }, SKShaderTileMode.Clamp)
        })
            c.DrawPath(tBoss, fp);

        var lb = tLock.Bounds;
        using (var fp = new SKPaint
        {
            IsAntialias = true,
            Shader = SKShader.CreateLinearGradient(new SKPoint(0, lb.Top), new SKPoint(0, lb.Bottom),
                new[] { Col(238, 228, 226), Col(170, 150, 150), Col(215, 200, 198) }, new[] { 0f, .55f, 1f }, SKShaderTileMode.Clamp)
        })
            c.DrawPath(tLock, fp);

        foreach (var (path, seed) in new[] { (tBoss, 17), (tLock, 29) })
        {
            c.Save();
            c.ClipPath(path, SKClipOperation.Intersect, true);
            using var gp = new SKPaint
            {
                Shader = SKShader.CreatePerlinNoiseTurbulence(.05f, .05f, 4, seed),
                ColorFilter = scene.GrungeRamp, BlendMode = SKBlendMode.Multiply
            };
            c.DrawRect(path.Bounds, gp);
            using var gp2 = new SKPaint
            {
                Shader = SKShader.CreatePerlinNoiseFractalNoise(.18f, .18f, 2, seed + 1),
                ColorFilter = scene.GrungeRamp, BlendMode = SKBlendMode.Multiply, Color = Col(255, 255, 255, 120)
            };
            c.DrawRect(path.Bounds, gp2);
            using var hl = new SKPaint { IsAntialias = true, Style = SKPaintStyle.Stroke, StrokeWidth = 2.2f, Color = Col(255, 150, 130, path == tBoss ? 130 : 90) };
            c.Save(); c.Translate(-1.5f, -1.5f); c.DrawPath(path, hl); c.Restore();
            c.Restore();
        }

        // Animated drips falling from text
        foreach (var d in scene.Drips)
        {
            Drip(c, d.X, d.Y, d.MaxLen, d.Width, time, d.Phase);
        }

        // Ornament under title
        Glow(c, scene.Wings, Col(255, 25, 10, 140), 6);
        using var wp = new SKPaint { IsAntialias = true, Color = Col(190, 14, 16) };
        c.DrawPath(scene.Wings, wp);
        
        using var halo = new SKPaint
        {
            BlendMode = SKBlendMode.Plus,
            Shader = SKShader.CreateRadialGradient(new SKPoint(862, 730), 50,
                new[] { Col(255, 40, 15, 160), Col(0, 0, 0, 0) }, null, SKShaderTileMode.Clamp)
        };
        c.DrawCircle(862, 730, 50, halo);
        
        c.Save();
        using var lp = new SKPaint
        {
            ColorFilter = SKColorFilter.CreateColorMatrix(new float[]
            { 1.2f, 0, 0, 0, 0,  0, .35f, 0, 0, 0,  0, 0, .3f, 0, 0,  0, 0, 0, 1, 0 })
        };
        c.SaveLayer(lp);
        DrawSkull(c, 862, 735, 0.175f, 0, false, 5, 0);
        c.Restore(); c.Restore();
    }

    static void Drip(SKCanvas c, float x, float y, float maxLen, float w, float time, float phase)
    {
        float cycle = 3.0f;
        float t = (time + phase) % cycle;
        float growTime = 2.0f;
        
        float len = t < growTime ? (t / growTime) * maxLen : maxLen;
        
        var p = new SKPath();
        p.MoveTo(x - w / 2, y); p.LineTo(x + w / 2, y);
        p.CubicTo(x + w / 2, y + len * .4f, x + w * .25f, y + len * .7f, x + w * .3f, y + len);
        p.LineTo(x - w * .3f, y + len);
        p.CubicTo(x - w * .25f, y + len * .7f, x - w / 2, y + len * .4f, x - w / 2, y);
        p.Close();
        p.AddCircle(x, y + len, w * .58f);
        
        using var fill = new SKPaint
        {
            IsAntialias = true,
            Shader = SKShader.CreateLinearGradient(new SKPoint(x, y), new SKPoint(x, y + len),
                new[] { Col(120, 0, 5), Col(205, 18, 18) }, null, SKShaderTileMode.Clamp)
        };
        c.DrawPath(p, fill);
        
        using var hl = new SKPaint { IsAntialias = true, Color = Col(255, 140, 120, 150), StrokeWidth = 1.1f, Style = SKPaintStyle.Stroke };
        if (len > 4) c.DrawLine(x - w * .12f, y + len * .35f, x - w * .12f, y + len, hl);
        
        // Falling droplet
        if (t > growTime)
        {
            float dropT = (t - growTime) / (cycle - growTime);
            float dropY = y + len + dropT * 60f;
            float dropAlpha = 1.0f - dropT;
            using var dropPaint = new SKPaint
            {
                IsAntialias = true,
                Color = Col(205, 18, 18, (int)(255 * dropAlpha))
            };
            c.DrawCircle(x, dropY, w * 0.6f, dropPaint);
        }
    }

    static void DrawEmbers(SKCanvas c, float time, List<Ember> embers)
    {
        foreach (var e in embers)
        {
            float y = e.Y - (time * e.Speed) % H;
            if (y < 0) y += H;
            
            float alpha = MathF.Sin(time * 2 + e.Phase) * 0.5f + 0.5f;
            int a = (int)(alpha * 255);
            
            using var ep = new SKPaint
            {
                IsAntialias = true, BlendMode = SKBlendMode.Plus,
                Color = Col(255, (int)(90 + 110 * alpha), 40, a),
                MaskFilter = SKMaskFilter.CreateBlur(SKBlurStyle.Normal, e.R * .7f)
            };
            c.DrawCircle(e.X, y, e.R, ep);
        }
    }
}

class SceneData
{
    public SKColorFilter FireRamp, FogRamp, GrayRamp, MoonRamp, SkinRamp, GrungeRamp;
    public SKShader RadialMaskCenter, RadialMaskLeft, VMaskBottom, RadialMaskFireLeft, RadialMaskFireRight;
    public List<Flame> Flames = new();
    public List<Ember> Embers = new();
    public List<DripData> Drips = new();
    public SKPath TextBoss, TextLock, Wings, Sil;
    public SKBitmap TextMask;

    public void Generate()
    {
        FireRamp = Ramp(v => (v * 3.2, (v - 70) * 2.6, (v - 135) * 3.2));
        FogRamp = Ramp(v => (v * 0.85, v * 0.07, v * 0.05));
        GrayRamp = Ramp(v => (v, v, v));
        MoonRamp = Ramp(v => (150 + v * 0.8, 40 + v * 0.4, 20 + v * 0.2));
        SkinRamp = Ramp(v => (120 + v * 0.9, 105 + v * 0.8, 100 + v * 0.8));
        GrungeRamp = Ramp(v => (150 + v * 0.5, 130 + v * 0.5, 130 + v * 0.5));

        RadialMaskCenter = RadialMask(Program.W * .5f, Program.H * .45f, 900, 1.2f, .9f, 255);
        RadialMaskLeft = RadialMask(120, 520, 420, 1f, 1.3f, 255);
        VMaskBottom = SKShader.CreateLinearGradient(new SKPoint(0, Program.H * .42f), new SKPoint(0, Program.H),
            new[] { Program.Col(255, 255, 255, 0), Program.Col(255, 255, 255, 120), Program.Col(255, 255, 255, 235) }, new[] { 0f, .6f, 1f }, SKShaderTileMode.Clamp);
        RadialMaskFireLeft = RadialMask(110, 800, 430, 1f, .8f, 255);
        RadialMaskFireRight = RadialMask(1560, 780, 460, 1f, .75f, 210);

        for (int i = 0; i < 70; i++)
        {
            float th = Program.Rf(-MathF.PI * 1.1f, MathF.PI * .1f);
            float bx = 830 + MathF.Cos(th) * 120, by = 270 - 40 + MathF.Sin(th) * 150;
            float dirx = MathF.Cos(th) * .7f + Program.Rf(-.3f, .3f), diry = MathF.Sin(th) - .6f;
            float dl = MathF.Sqrt(dirx * dirx + diry * diry); dirx /= dl; diry /= dl;
            float len = Program.Rf(70, 260), wd = Program.Rf(18, 46);
            float tx = bx + dirx * len + Program.Rf(-30, 30), ty = by + diry * len;
            Flames.Add(new Flame { Bx = bx, By = by, Tx = tx, Ty = ty, Wd = wd, Phase = Program.Rf(0, 6.28f) });
        }

        for (int i = 0; i < 320; i++)
        {
            float x = Program.Rf(0, Program.W);
            float y = (float)Math.Pow(Program.rnd.NextDouble(), .8) * Program.H;
            float r = Program.rnd.NextDouble() < .08 ? Program.Rf(2, 3.6f) : Program.Rf(.6f, 1.8f);
            float speed = Program.Rf(20, 80);
            Embers.Add(new Ember { X = x, Y = y, R = r, Speed = speed, Phase = Program.Rf(0, 6.28f) });
        }

        var tf = Gothic();
        if (tf == null) tf = SKTypeface.FromFamilyName("serif", SKFontStyle.Bold);
        TextBoss = TextPath(tf, "BossDefender", 845, 668, 1060, 0f);
        TextLock = TextPath(tf, "Locked by", 835, 498, 470, .10f);

        Wings = new SKPath();
        var cen = new SKPoint(862, 738);
        for (int side = -1; side <= 1; side += 2)
        {
            Wings.AddPath(Taper(cen, new SKPoint(862 + side * 170, 688), new SKPoint(862 + side * 322, 722), 8));
            Wings.AddPath(Taper(cen, new SKPoint(862 + side * 120, 724), new SKPoint(862 + side * 250, 776), 6));
            Wings.AddPath(Taper(cen, new SKPoint(862 + side * 190, 738), new SKPoint(862 + side * 335, 746), 3.5f));
            for (int k = 0; k < 5; k++)
            {
                float t = .18f + k * .15f;
                float px = 862 + side * 320 * t, py = 738 - 22 * MathF.Sin(t * 3.14f) * 1.3f;
                Wings.AddPath(Taper(new SKPoint(px, py), new SKPoint(px + side * 8, py - 12), new SKPoint(px + side * 22, py - 26 + k * 2), 5));
            }
        }
        Wings.AddPath(Taper(new SKPoint(862, 760), new SKPoint(862, 830), new SKPoint(862, 905), 8));

        Sil = SKPath.ParseSvgPathData(
            "M0,-185 C85,-185 142,-125 139,-48 C138,-8 122,16 113,42 C106,66 96,84 86,100 L78,128 C74,142 66,150 56,154 " +
            "L40,168 C20,172 -20,172 -40,168 L-56,154 C-66,150 -74,142 -78,128 L-86,100 C-96,84 -106,66 -113,42 " +
            "C-122,16 -138,-8 -139,-48 C-142,-125 -85,-185 0,-185 Z");

        TextMask = new SKBitmap(Program.W, Program.H);
        using (var mc = new SKCanvas(TextMask))
        {
            mc.Clear(SKColors.Transparent);
            using var mp = new SKPaint { IsAntialias = true, Color = SKColors.White };
            mc.DrawPath(TextBoss, mp); mc.DrawPath(TextLock, mp);
        }

        float lastX = -100;
        var b = TextBoss.Bounds;
        for (int x = (int)b.Left; x < (int)b.Right; x += 3)
        {
            for (int y = (int)b.Top; y < (int)b.Bottom; y++)
            {
                if (TextMask.GetPixel(x, y).Alpha > 140 && TextMask.GetPixel(x, y + 1).Alpha <= 140)
                {
                    if (x - lastX > 9 && Program.rnd.NextDouble() < .20)
                    {
                        float len = Program.rnd.NextDouble() < .2 ? Program.Rf(60, 120) : Program.Rf(12, 52);
                        Drips.Add(new DripData { X = x, Y = y - 3, MaxLen = len, Width = Program.Rf(2.4f, 5.2f), Phase = Program.Rf(0, 3.0f) });
                        lastX = x;
                    }
                    break;
                }
            }
        }
        var l = TextLock.Bounds;
        lastX = -100;
        for (int x = (int)l.Left; x < (int)l.Right; x += 3)
        {
            for (int y = (int)l.Top; y < (int)l.Bottom; y++)
            {
                if (TextMask.GetPixel(x, y).Alpha > 140 && TextMask.GetPixel(x, y + 1).Alpha <= 140)
                {
                    if (x - lastX > 20 && Program.rnd.NextDouble() < .08)
                    {
                        Drips.Add(new DripData { X = x, Y = y - 2, MaxLen = Program.Rf(8, 24), Width = Program.Rf(2f, 3.4f), Phase = Program.Rf(0, 3.0f) });
                        lastX = x;
                    }
                    break;
                }
            }
        }
    }

    public SKColorFilter Ramp(Func<int, (int r, int g, int b)> f)
    {
        var tr = new byte[256]; var tg = new byte[256]; var tb = new byte[256]; var ta = new byte[256];
        for (int i = 0; i < 256; i++)
        {
            var (r, g, b) = f(i);
            tr[i] = (byte)Program.Cl(r); tg[i] = (byte)Program.Cl(g); tb[i] = (byte)Program.Cl(b); ta[i] = 255;
        }
        var gray = SKColorFilter.CreateColorMatrix(new float[]
        {
            1, 0, 0, 0, 0,
            1, 0, 0, 0, 0,
            1, 0, 0, 0, 0,
            0, 0, 0, 0, 1
        });
        return SKColorFilter.CreateCompose(SKColorFilter.CreateTable(ta, tr, tg, tb), gray);
    }

    public SKShader RadialMask(float cx, float cy, float r, float sx, float sy, int a0)
    {
        return SKShader.CreateRadialGradient(new SKPoint(cx, cy), r,
            new[] { Program.Col(255, 255, 255, a0), Program.Col(255, 255, 255, a0 * 6 / 10), Program.Col(255, 255, 255, 0) },
            new[] { 0f, 0.5f, 1f }, SKShaderTileMode.Clamp, SKMatrix.CreateScale(sx, sy, cx, cy));
    }

    public SKPath Taper(SKPoint a, SKPoint ctl, SKPoint b, float w0, float w1 = 0f, int n = 40)
    {
        var left = new List<SKPoint>(); var right = new List<SKPoint>();
        for (int i = 0; i <= n; i++)
        {
            float t = i / (float)n, u = 1 - t;
            float px = u * u * a.X + 2 * u * t * ctl.X + t * t * b.X;
            float py = u * u * a.Y + 2 * u * t * ctl.Y + t * t * b.Y;
            float tx = 2 * u * (ctl.X - a.X) + 2 * t * (b.X - ctl.X);
            float ty = 2 * u * (ctl.Y - a.Y) + 2 * t * (b.Y - ctl.Y);
            float len = MathF.Sqrt(tx * tx + ty * ty); if (len < 1e-4f) len = 1;
            float nx = -ty / len, ny = tx / len;
            float hw = (w0 * (1 - t) + w1 * t) / 2f;
            left.Add(new SKPoint(px + nx * hw, py + ny * hw));
            right.Add(new SKPoint(px - nx * hw, py - ny * hw));
        }
        var p = new SKPath();
        p.MoveTo(left[0]);
        for (int i = 1; i < left.Count; i++) p.LineTo(left[i]);
        for (int i = right.Count - 1; i >= 0; i--) p.LineTo(right[i]);
        p.Close();
        return p;
    }

    public SKTypeface Gothic()
    {
        var sys = FindFont("UnifrakturCook", "UnifrakturMaguntia", "Pirata One", "Grenze Gotisch", "Old English Text MT",
            "Blackadder ITC", "Fraktur", "Germania One", "Metal Mania", "Chiller", "New Rocker");
        if (sys != null) return sys;
        var cache = Path.Combine(Path.GetTempPath(), "ghost_unifraktur.ttf");
        try
        {
            if (!File.Exists(cache))
            {
                using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(8) };
                var bytes = http.GetByteArrayAsync("https://github.com/google/fonts/raw/main/ofl/unifrakturcook/UnifrakturCook-Bold.ttf")
                                .GetAwaiter().GetResult();
                File.WriteAllBytes(cache, bytes);
            }
            return SKTypeface.FromFile(cache);
        }
        catch { }
        return null;
    }

    public SKTypeface FindFont(params string[] names)
    {
        foreach (var n in names)
        {
            var tf = SKTypeface.FromFamilyName(n);
            if (tf != null && tf.FamilyName.Equals(n, StringComparison.OrdinalIgnoreCase)) return tf;
        }
        return null;
    }

    public SKPath TextPath(SKTypeface tf, string text, float cx, float baseline, float targetW, float track)
    {
        float Measure(float sz)
        {
            using var f = new SKFont(tf, sz);
            float t = 0; foreach (var ch in text) t += f.MeasureText(ch.ToString());
            return t + track * sz * (text.Length - 1);
        }
        float size = 100f * targetW / Measure(100f);
        using var font = new SKFont(tf, size) { Subpixel = true, Edging = SKFontEdging.Antialias };
        var path = new SKPath(); float x = cx - targetW / 2;
        foreach (var ch in text)
        {
            var s = ch.ToString();
            path.AddPath(font.GetTextPath(s, new SKPoint(x, baseline)));
            x += font.MeasureText(s) + track * size;
        }
        return path;
    }
}

class Flame { public float Bx, By, Tx, Ty, Wd, Phase; }
class Ember { public float X, Y, R, Speed, Phase; }
class DripData { public float X, Y, MaxLen, Width, Phase; }
