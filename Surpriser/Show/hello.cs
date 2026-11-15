// =============================================================================
//  >>>>>>>>>>>>>>>>>>>>>>>>  CHANGE THESE TO ANYTHING  <<<<<<<<<<<<<<<<<<<<<<<<
// =============================================================================
static class Settings
{
    // Line 1: BIG, colorful, thunder-strike animation. Keep it short (a few words).
    public const string TELL = "Hello Boss";

    // Line 2: normal size, colorful, typed out like a real person. Can be a whole
    //         paragraph. Put \n inside the text for a new paragraph.
    public const string TELLAGAIN = "You have been hacked. However how's your day going? Everything allright? I hope we can meet someday!";

    // TYPING SPEED of line 2, in words per minute. Set any number you like:
    //   50 = relaxed, 70 = normal, 90 = fast, 100+ = very fast.
    public const int WPM = 120;
}
// =============================================================================
//  hello.cs - Windows version (Windows 10 / 11).
//  Opens a NEW console window and shows TELL + TELLAGAIN.
//
//  Build (no install needed - csc.exe ships with Windows):
//    %WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe /nologo /out:hello.exe hello.cs
//
//  Run:
//    hello.exe
//    hello.exe "I Have Linux, Bro"               -> overrides TELL
//    hello.exe "Blockbuster Boss" "Some text"    -> overrides both
//  Skip: press any key while it types to finish instantly.
// =============================================================================

namespace HelloApp
{
    using System;
    using System.Collections.Generic;
    using System.Diagnostics;
    using System.IO;
    using System.Reflection;
    using System.Runtime.InteropServices;
    using System.Text;
    using System.Threading;

    class Program
    {
        const string ESC = "\u001b";

        // Rainbow for the big banner (256-color codes) - flows smoothly, never shakes.
        static readonly int[] Pal = { 196, 202, 208, 214, 220, 226, 190, 154, 118, 46, 48, 51, 45, 39, 33, 27, 57, 93, 129, 165, 201, 199, 198, 197 };
        // Softer rainbow for the typed line.
        static readonly int[] TPal = { 209, 215, 221, 227, 191, 155, 119, 85, 86, 87, 81, 75, 69, 105, 141, 177, 213, 212, 211, 210 };
        static readonly Random Rng = new Random();

        // Built-in big font (5 rows high). "/" separates rows, '#' = filled pixel.
        static readonly Dictionary<char, string> Font = new Dictionary<char, string>
        {
            {'A', ".###./#...#/#####/#...#/#...#"}, {'B', "####./#...#/####./#...#/####."},
            {'C', ".####/#..../#..../#..../.####"}, {'D', "####./#...#/#...#/#...#/####."},
            {'E', "#####/#..../####./#..../#####"}, {'F', "#####/#..../####./#..../#...."},
            {'G', ".####/#..../#..##/#...#/.####"}, {'H', "#...#/#...#/#####/#...#/#...#"},
            {'I', "#####/..#../..#../..#../#####"}, {'J', "..###/...#./...#./#..#./.##.."},
            {'K', "#...#/#..#./###../#..#./#...#"}, {'L', "#..../#..../#..../#..../#####"},
            {'M', "#...#/##.##/#.#.#/#...#/#...#"}, {'N', "#...#/##..#/#.#.#/#..##/#...#"},
            {'O', ".###./#...#/#...#/#...#/.###."}, {'P', "####./#...#/####./#..../#...."},
            {'Q', ".###./#...#/#.#.#/#..#./.##.#"}, {'R', "####./#...#/####./#..#./#...#"},
            {'S', ".####/#..../.###./....#/####."}, {'T', "#####/..#../..#../..#../..#.."},
            {'U', "#...#/#...#/#...#/#...#/.###."}, {'V', "#...#/#...#/#...#/.#.#./..#.."},
            {'W', "#...#/#...#/#.#.#/##.##/#...#"}, {'X', "#...#/.#.#./..#../.#.#./#...#"},
            {'Y', "#...#/.#.#./..#../..#../..#.."}, {'Z', "#####/...#./..#../.#.../#####"},
            {'0', ".###./#..##/#.#.#/##..#/.###."}, {'1', "..#../.##../..#../..#../.###."},
            {'2', ".###./#...#/...#./..#../#####"}, {'3', "####./....#/.###./....#/####."},
            {'4', "#..#./#..#./#####/...#./...#."}, {'5', "#####/#..../####./....#/####."},
            {'6', ".###./#..../####./#...#/.###."}, {'7', "#####/....#/...#./..#../..#.."},
            {'8', ".###./#...#/.###./#...#/.###."}, {'9', ".###./#...#/.####/....#/.###."},
            {'!', ".#./.#./.#./.../.#."},           {'?', ".###./#...#/..##./...../..#.."},
            {'.', ".../.../.../.../.#."},           {',', ".../.../.../.#./#.."},
            {':', ".../.#./.../.#./..."},           {';', ".../.#./.../.#./#.."},
            {'\'', ".#./.#./.../.../..."},          {'"', "#.#/#.#/.../.../..."},
            {'-', "..../..../####/..../...."},      {'_', "...../...../...../...../#####"},
            {'+', "...../..#../.###./..#../....."}, {'=', "...../#####/...../#####/....."},
            {'/', "....#/...#./..#../.#.../#...."}, {'(', "..#/.#./.#./.#./..#"},
            {')', "#../.#./.#./.#./#.."},           {'<', "...#/..#./.#../..#./...#"},
            {'>', "#.../.#../..#./.#../#..."},      {'*', "...../#.#.#/.###./#.#.#/....."},
            {'#', ".#.#./#####/.#.#./#####/.#.#."}, {'@', ".###./#.###/#.#.#/#.##./.###."},
            {'&', ".##../#..#./.##.#/#..#./.##.#"}, {'$', ".####/#.#../.###./..#.#/####."},
            {'%', "##..#/##.#./..#../.#.##/#..##"}, {' ', "..../..../..../..../...."}
        };

        // ---- layout state ----
        static int Cols, Rows, PW, BRow;
        static List<string> BLines = new List<string>();
        static List<string[]> Txt = new List<string[]>();   // 5 rows per banner line: 'X' block, ' ' empty
        static List<int> WPx = new List<int>();
        static List<int> LCol = new List<int>();

        // ---- Windows console: turn on ANSI colors ----
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr GetStdHandle(int nStdHandle);
        [DllImport("kernel32.dll")]
        static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
        [DllImport("kernel32.dll")]
        static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);

        static void EnableAnsi()
        {
            try
            {
                IntPtr h = GetStdHandle(-11); // STD_OUTPUT_HANDLE
                uint mode;
                if (GetConsoleMode(h, out mode))
                    SetConsoleMode(h, mode | 0x0004 | 0x0001); // VIRTUAL_TERMINAL_PROCESSING | PROCESSED_OUTPUT
            }
            catch { }
        }

        // =====================================================================
        static void Main(string[] args)
        {
            string tell = Settings.TELL, again = Settings.TELLAGAIN;
            if (args.Length > 0 && args[0] == "--show")
            {
                if (args.Length > 1) tell = Decode(args[1]);
                if (args.Length > 2) again = Decode(args[2]);
                Show(tell, again);
                return;
            }
            if (args.Length > 0) tell = args[0];
            if (args.Length > 1) again = args[1];
            Launch(tell, again);
        }

        // Text travels to the new window as Base64 so quotes/newlines survive.
        static string Encode(string s) { return Convert.ToBase64String(Encoding.UTF8.GetBytes(s)); }
        static string Decode(string s)
        {
            try { return Encoding.UTF8.GetString(Convert.FromBase64String(s)); }
            catch { return s; }
        }

        // Start ourselves again in a brand-new console window.
        static void Launch(string tell, string again)
        {
            try
            {
                string host = Process.GetCurrentProcess().MainModule.FileName;
                string lead = "";
                // if started through "dotnet run", re-launch via the dotnet host
                if (Path.GetFileNameWithoutExtension(host).Equals("dotnet", StringComparison.OrdinalIgnoreCase))
                    lead = "\"" + Assembly.GetEntryAssembly().Location + "\" ";

                ProcessStartInfo psi = new ProcessStartInfo();
                psi.FileName = host;
                psi.Arguments = lead + "--show " + Encode(tell) + " " + Encode(again);
                psi.UseShellExecute = true;   // => Windows gives it its own new window
                Process.Start(psi);
            }
            catch
            {
                Show(tell, again); // could not open a new window: show it here instead
            }
        }

        // =====================================================================
        //  Everything below runs INSIDE the new window.
        // =====================================================================
        static void Show(string tell, string again)
        {
            EnableAnsi();
            try { Console.OutputEncoding = new UTF8Encoding(false); } catch { }
            try { Console.Title = tell; } catch { }
            try { ResizeWindow(); } catch { }
            try { Console.CursorVisible = false; } catch { }
            Out(ESC + "[0m" + ESC + "[2J" + ESC + "[H");
            Thread.Sleep(300);

            try { Cols = Console.WindowWidth; Rows = Console.WindowHeight; }
            catch { Cols = 100; Rows = 30; }
            if (Cols < 20) Cols = 80;
            if (Rows < 10) Rows = 24;

            List<string> words = new List<string>(tell.ToUpperInvariant().Split(new char[] { ' ', '\t', '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries));
            if (words.Count == 0) words.Add("HELLO");

            int tw = Math.Max(20, Math.Min(78, Cols - 8));
            List<string> plines = Wrap(again, tw);
            int maxLen = 0;
            foreach (string l in plines) if (l.Length > maxLen) maxLen = l.Length;
            int pl = plines.Count;

            // Big (2 columns per pixel) if it fits, otherwise smaller.
            PW = 2; BLines = Pack(words, 2);
            int bh = BLines.Count * 6 - 1;
            if (bh + pl + 7 > Rows) { PW = 1; BLines = Pack(words, 1); bh = BLines.Count * 6 - 1; }
            bool fits = bh + pl + 7 <= Rows;

            int top = Math.Max(0, (Rows - (bh + pl + 6)) / 2);
            BRow = 2 + top;
            int pRow = BRow + bh + 2;
            int pCol = Math.Max(1, (Cols - maxLen) / 2 + 1);
            string pads = new string(' ', pCol - 1);

            BuildBanner();
            int nfr = Pal.Length * 2;
            string fWhite = Render(0, 231), fBlue = Render(0, 51), fDim = Render(0, 54);

            StringBuilder fill = new StringBuilder();
            string blank = new string(' ', Cols - 1);
            for (int r = 1; r <= Rows; r++) fill.Append(ESC + "[" + r + ";1H" + blank);
            string fillStr = fill.ToString();

            StringBuilder bsb = new StringBuilder();
            for (int i = 0; i < Cols - 1; i++) bsb.Append(i % 2 == 1 ? '\u2584' : '\u2580');
            string border = ESC + "[38;5;54m" + bsb.ToString() + ESC + "[0m";

            // ------------------------- THUNDER STRIKE INTRO -------------------------
            Thread.Sleep(500);
            Flash(255, 50, fillStr); Thread.Sleep(80);
            Flash(231, 90, fillStr); Thread.Sleep(50);
            Out(fWhite); Thread.Sleep(120);
            Out(ESC + "[2J"); Thread.Sleep(350);
            Flash(231, 40, fillStr);
            Out(fWhite); Thread.Sleep(70);
            Out(fBlue); Thread.Sleep(70);
            Out(fWhite); Thread.Sleep(60);
            Out(fDim); Thread.Sleep(250);
            Out(ESC + "[1;1H" + border);
            if (fits) Out(ESC + "[" + Rows + ";1H" + border);
            for (int i = 0; i < nfr / 2; i++) { Out(Render(i, -1)); Thread.Sleep(60); }
            int tick = nfr / 2;

            // -------------------------- TYPE THE SECOND LINE ------------------------
            int wpm = Settings.WPM > 0 ? Settings.WPM : 45;
            int baseMs = 12000 / wpm;                       // ms per character
            bool skip = false;
            int cidx = 0;
            Stopwatch sw = Stopwatch.StartNew();
            long due = 0;
            Out(ESC + "[" + pRow + ";" + pCol + "H");
            for (int j = 0; j < pl; j++)
            {
                string line = plines[j];
                if (j > 0) Out("\r\n" + pads);
                for (int i = 0; i < line.Length; i++)
                {
                    char ch = line[i];
                    int col = TPal[(cidx / 2) % TPal.Length]; cidx++;
                    Out(ESC + "[22;38;5;" + col + "m" + ch + ESC + "[38;5;252m\u258C" + ESC + "[D");
                    if (skip) continue;
                    int d = baseMs * (60 + Rng.Next(81)) / 100;
                    if (ch == '.' || ch == '!' || ch == '?') d += 350;
                    else if (ch == ',' || ch == ';' || ch == ':') d += 150;
                    else if (ch == ' ') d = d * 7 / 10;
                    if (fits) { tick++; Out(ESC + "7" + Render(tick, -1) + ESC + "8"); }
                    due += d;
                    if (WaitKeyUntil(sw, due)) skip = true;
                }
                Out(" \b" + ESC + "[0m");
            }

            // ---------------- footer, then keep the banner gently alive ---------------
            string t2 = "[ press any key to escape ]";
            Out("\r\n\r\n" + new string(' ', Math.Max(0, (Cols - t2.Length) / 2)) + ESC + "[38;5;240m" + t2 + ESC + "[0m");
            if (fits)
            {
                int strike = 40 + Rng.Next(40);
                while (true)
                {
                    tick++;
                    if (tick % strike == 0)                  // a lightning strike now and then
                    {
                        Out(ESC + "7" + fWhite + ESC + "8"); Thread.Sleep(60);
                        Out(ESC + "7" + fBlue + ESC + "8"); Thread.Sleep(50);
                        strike = 40 + Rng.Next(40);
                    }
                    Out(ESC + "7" + Render(tick, -1) + ESC + "8");
                    if (WaitKeyUntil(sw, sw.ElapsedMilliseconds + 80)) break;
                }
            }
            else
            {
                while (!WaitKeyUntil(sw, sw.ElapsedMilliseconds + 200)) { }
            }
            Out(ESC + "[0m" + ESC + "[2J" + ESC + "[H" + ESC + "[?25h");
            try { Console.CursorVisible = true; } catch { }
        }

        static void Out(string s) { Console.Write(s); }

        static void Flash(int bg, int ms, string fill)
        {
            Out(ESC + "[48;5;" + bg + "m" + ESC + "[2J" + fill + ESC + "[0m");
            Thread.Sleep(ms);
            Out(ESC + "[0m" + ESC + "[2J");
        }

        // Wait until the stopwatch reaches 'dueMs'; true if a key was pressed.
        static bool WaitKeyUntil(Stopwatch sw, long dueMs)
        {
            do
            {
                if (KeyPressed()) return true;
                Thread.Sleep(10);
            } while (sw.ElapsedMilliseconds < dueMs);
            return false;
        }

        static bool KeyPressed()
        {
            try
            {
                if (Console.KeyAvailable) { Console.ReadKey(true); return true; }
                return false;
            }
            catch { return false; }
        }

        static void ResizeWindow()
        {
            int w = Math.Min(100, Console.LargestWindowWidth);
            int h = Math.Min(34, Console.LargestWindowHeight);
            if (w < 60 || h < 20) return;
            Console.SetBufferSize(Math.Max(Console.BufferWidth, w), Math.Max(Console.BufferHeight, h));
            Console.SetWindowSize(w, h);
            Console.SetBufferSize(w, h);
        }

        static string Glyph(char c)
        {
            string g;
            if (!Font.TryGetValue(c, out g)) g = Font[' '];
            return g;
        }

        static int TextPx(string s)
        {
            int w = 0;
            foreach (char c in s) w += Glyph(c).Split('/')[0].Length + 1;
            return w;
        }

        // Pack the words of TELL into banner lines that fit the window.
        static List<string> Pack(List<string> words, int pw)
        {
            int maxPx = (Cols - 4) / pw;
            List<string> lines = new List<string>();
            string cur = ""; int curPx = 0;
            foreach (string w in words)
            {
                int wpx = TextPx(w);
                if (wpx > maxPx)                     // one giant word: break it up
                {
                    if (cur.Length > 0) lines.Add(cur);
                    string chunk = "";
                    foreach (char ch in w)
                    {
                        if (TextPx(chunk + ch) > maxPx && chunk.Length > 0) { lines.Add(chunk); chunk = ch.ToString(); }
                        else chunk += ch;
                    }
                    cur = chunk; curPx = TextPx(cur);
                    continue;
                }
                if (cur.Length == 0) { cur = w; curPx = wpx; }
                else if (curPx + 5 + wpx <= maxPx) { cur = cur + " " + w; curPx += 5 + wpx; }
                else { lines.Add(cur); cur = w; curPx = wpx; }
            }
            if (cur.Length > 0) lines.Add(cur);
            return lines;
        }

        // Word-wrap TELLAGAIN to 'width' columns, keeping paragraph breaks.
        static List<string> Wrap(string text, int width)
        {
            List<string> outl = new List<string>();
            string[] paras = text.Replace("\r\n", "\n").Replace('\r', '\n').Split('\n');
            foreach (string para in paras)
            {
                string line = "";
                foreach (string w0 in para.Split(new char[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries))
                {
                    string w = w0;
                    while (w.Length > width)
                    {
                        if (line.Length > 0) { outl.Add(line); line = ""; }
                        outl.Add(w.Substring(0, width)); w = w.Substring(width);
                    }
                    if (line.Length == 0) line = w;
                    else if (line.Length + 1 + w.Length <= width) line = line + " " + w;
                    else { outl.Add(line); line = w; }
                }
                outl.Add(line);
            }
            return outl;
        }

        // Build the pixel rows of every banner line.
        static void BuildBanner()
        {
            Txt.Clear(); WPx.Clear(); LCol.Clear();
            foreach (string text in BLines)
            {
                StringBuilder[] bm = new StringBuilder[5];
                for (int r = 0; r < 5; r++) bm[r] = new StringBuilder();
                foreach (char c in text)
                {
                    string[] g = Glyph(c).Split('/');
                    for (int r = 0; r < 5; r++) bm[r].Append(g[r]).Append('.');
                }
                int w = bm[0].Length - 1;                 // drop the trailing gap
                string[] rows = new string[5];
                for (int r = 0; r < 5; r++)
                {
                    string b = bm[r].ToString();
                    StringBuilder sb = new StringBuilder();
                    for (int c = 0; c < w; c++) sb.Append(b[c] == '#' ? 'X' : ' ', PW);
                    rows[r] = sb.ToString();
                }
                Txt.Add(rows);
                WPx.Add(w);
                LCol.Add(Math.Max(1, (Cols - w * PW) / 2 + 1));
            }
        }

        // One banner frame. 'off' slides the rainbow, 'fixed' >= 0 = one solid color.
        static string Render(int off, int fixedColor)
        {
            const int S = 2;
            StringBuilder sb = new StringBuilder();
            for (int L = 0; L < BLines.Count; L++)
            {
                int w = WPx[L];
                for (int r = 0; r < 5; r++)
                {
                    string txt = Txt[L][r];
                    sb.Append(ESC + "[" + (BRow + L * 6 + r) + ";" + LCol[L] + "H");
                    int c = 0;
                    while (c < w)
                    {
                        int b = (c + r + off) / S;
                        int len = (b + 1) * S - (c + r + off);
                        if (c + len > w) len = w - c;
                        string seg = txt.Substring(c * PW, len * PW);
                        if (seg.IndexOf('X') >= 0)
                        {
                            int col = fixedColor >= 0 ? fixedColor : Pal[b % Pal.Length];
                            sb.Append(ESC + "[38;5;" + col + "m");
                            sb.Append(seg.Replace('X', '\u2588'));
                        }
                        else sb.Append(seg);
                        c += len;
                    }
                }
            }
            sb.Append(ESC + "[0m");
            return sb.ToString();
        }
    }
}
