using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.IO.Pipes;
using System.Security.AccessControl;
using System.Security.Principal;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;
using System.Runtime.InteropServices;

sealed class ViewerOptions {
    static readonly Regex LocalAbsolutePath = new Regex("\\A[A-Za-z]:[\\\\/]", RegexOptions.CultureInvariant);
    internal string ConfigPath;
    internal string PythonPath;
    internal string SelfTestPath;
    internal string HotkeyStatusPath;
    internal bool ShowOnStart;
    internal bool QuietControlError;
    internal bool HostHotkeyEnabled = true;
    internal int[] ChannelHotkeys;

    internal static ViewerOptions Parse(string[] args) {
        ViewerOptions result = new ViewerOptions();
        HashSet<string> seen = new HashSet<string>(StringComparer.Ordinal);
        for (int index = 0; index < args.Length;) {
            string option = args[index];
            if (!seen.Add(option)) throw new ArgumentException("Expected unique options.");
            if (option == "--show") { result.ShowOnStart = true; index++; continue; }
            if (option == "--quiet-control-error") { result.QuietControlError = true; index++; continue; }
            if (option == "--no-host-hotkey") { result.HostHotkeyEnabled = false; index++; continue; }
            if (index + 1 >= args.Length) throw new ArgumentException("Expected option/value pairs.");
            string value = args[index + 1];
            if (String.IsNullOrWhiteSpace(value)) throw new ArgumentException("Option values must not be empty.");
            switch (option) {
                case "--config": result.ConfigPath = RequireLocalPath(value, "config"); break;
                case "--python": result.PythonPath = RequireExistingFile(value, "python"); break;
                case "--self-test": result.SelfTestPath = RequireOutputPath(value); break;
                case "--hotkey-status": result.HotkeyStatusPath = RequireOutputPath(value); break;
                case "--channel-hotkeys": result.ChannelHotkeys = ParseDigits(value); break;
                default: throw new ArgumentException("Unknown option.");
            }
            index += 2;
        }
        if (result.ConfigPath == null || result.PythonPath == null)
            throw new ArgumentException("--config and --python are required.");
        return result;
    }

    static int[] ParseDigits(string value) {
        string[] parts = value.Split(',');
        int[] digits = new int[parts.Length];
        HashSet<int> seen = new HashSet<int>();
        for (int index = 0; index < parts.Length; index++) {
            if (parts[index].Length != 1 || parts[index][0] < '1' || parts[index][0] > '9')
                throw new ArgumentException("--channel-hotkeys requires comma-separated digits 1..9.");
            digits[index] = parts[index][0] - '0';
            if (!seen.Add(digits[index])) throw new ArgumentException("Channel hotkeys must be unique.");
        }
        return digits;
    }

    internal HotkeyMap HotkeysFor(int channelCount) {
        if (channelCount < 1 || channelCount > 8) throw new ArgumentException("Expected 1..8 channels.");
        int[] digits = ChannelHotkeys;
        if (digits == null) {
            digits = new int[channelCount];
            for (int index = 0; index < channelCount; index++) digits[index] = index + 2;
        }
        if (digits.Length != channelCount) throw new ArgumentException("--channel-hotkeys must contain one digit per configured channel.");
        if (HostHotkeyEnabled && Array.IndexOf(digits, 1) >= 0)
            throw new ArgumentException("Alt+1 is reserved for the host; use --no-host-hotkey or another channel key.");
        return new HotkeyMap(HostHotkeyEnabled, digits);
    }

    static string RequireExistingFile(string value, string label) {
        string path = RequireLocalPath(value, label);
        if (!File.Exists(path)) throw new FileNotFoundException(label + " file was not found.");
        return path;
    }

    static string RequireLocalPath(string value, string label) {
        if (!LocalAbsolutePath.IsMatch(value)) throw new ArgumentException(label + " path must be a fully qualified local drive path.");
        return Path.GetFullPath(value);
    }

    static string RequireOutputPath(string value) {
        if (!LocalAbsolutePath.IsMatch(value)) throw new ArgumentException("output path must be a fully qualified local drive path.");
        string path = Path.GetFullPath(value);
        string parent = Path.GetDirectoryName(path);
        if (String.IsNullOrEmpty(parent) || !Directory.Exists(parent))
            throw new DirectoryNotFoundException("output directory was not found.");
        return path;
    }
}

sealed class HotkeyMap {
    internal readonly bool HostEnabled;
    internal readonly int[] Channels;
    internal HotkeyMap(bool hostEnabled, int[] channels) { HostEnabled = hostEnabled; Channels = channels; }
    internal string HostLabel { get { return HostEnabled ? "Alt+1" : "托盘"; } }
    internal string ChannelLabel(int index) { return "Alt+" + Channels[index]; }
    internal string ChannelSummary() {
        List<string> labels = new List<string>();
        for (int index = 0; index < Channels.Length; index++) labels.Add(ChannelLabel(index));
        return String.Join(" / ", labels.ToArray());
    }
}

sealed class ViewerRequest {
    public string ConfigPath;
    public bool HostEnabled;
    public int[] Channels;
    public bool Show;
    public string StatusPath;
    public bool ReturnToHost;
}

static class ViewerInstance {
    // An explicit GUID keeps integration tests away from a user's running viewer.
    internal static string Suffix {
        get {
            string value = Environment.GetEnvironmentVariable("QICHENG_WINDOWS_VIEWER_TEST_SCOPE");
            Guid scope;
            return Guid.TryParseExact(value, "N", out scope) ? ".test." + scope.ToString("N") : "";
        }
    }
    internal static string MutexName { get { return @"Local\Qicheng.WindowsChannels.Viewer" + Suffix; } }
    internal static string ActivationName { get { return @"Local\Qicheng.WindowsChannels.Viewer.Activate" + Suffix; } }
}

static class ViewerControl {
    internal static string PipeName {
        get { return "Qicheng.WindowsChannels.Viewer." + Process.GetCurrentProcess().SessionId + ViewerInstance.Suffix; }
    }

    internal static void Send(ViewerOptions options, HotkeyMap map) {
        using (NamedPipeClientStream pipe = new NamedPipeClientStream(".", PipeName, PipeDirection.InOut)) {
            pipe.Connect(3000);
            using (StreamReader reader = new StreamReader(pipe, Encoding.UTF8))
            using (StreamWriter writer = new StreamWriter(pipe, new UTF8Encoding(false)) { AutoFlush = true }) {
                writer.WriteLine(new JavaScriptSerializer().Serialize(new ViewerRequest {
                    ConfigPath = options.ConfigPath, HostEnabled = map.HostEnabled, Channels = map.Channels,
                    Show = options.ShowOnStart, StatusPath = options.HotkeyStatusPath, ReturnToHost = false
                }));
                Task<string> responseRead = Task.Factory.StartNew(delegate { return reader.ReadLine(); });
                if (!responseRead.Wait(15000)) throw new TimeoutException("control-response-timeout");
                string response = responseRead.Result;
                if (response != "ok") throw new InvalidOperationException("control-response:" + (response ?? "closed"));
            }
        }
    }

    internal static void Serve(ViewerForm form) {
        Thread worker = new Thread(delegate() {
            while (!form.IsDisposed) {
                try {
                    PipeSecurity security = new PipeSecurity();
                    security.AddAccessRule(new PipeAccessRule(WindowsIdentity.GetCurrent().User, PipeAccessRights.ReadWrite, AccessControlType.Allow));
                    using (NamedPipeServerStream pipe = new NamedPipeServerStream(PipeName, PipeDirection.InOut, 1,
                        PipeTransmissionMode.Byte, PipeOptions.None, 4096, 4096, security)) {
                        pipe.WaitForConnection();
                        using (StreamReader reader = new StreamReader(pipe, Encoding.UTF8))
                        using (StreamWriter writer = new StreamWriter(pipe, new UTF8Encoding(false)) { AutoFlush = true }) {
                            try {
                                Task<string> requestRead = Task.Factory.StartNew(delegate { return reader.ReadLine(); });
                                if (!requestRead.Wait(5000)) throw new TimeoutException("control-request-timeout");
                                ViewerRequest request = new JavaScriptSerializer().Deserialize<ViewerRequest>(requestRead.Result);
                                TaskCompletionSource<bool> completion = new TaskCompletionSource<bool>();
                                int requestState = 0;
                                form.BeginInvoke(new Action(delegate() {
                                    if (Interlocked.CompareExchange(ref requestState, 1, 0) != 0) return;
                                    try { completion.SetResult(form.ApplyRequest(request)); }
                                    catch (Exception) { completion.SetResult(false); }
                                }));
                                if (!completion.Task.Wait(8000) && Interlocked.CompareExchange(ref requestState, 2, 0) == 1)
                                    completion.Task.Wait();
                                bool accepted = completion.Task.IsCompleted && completion.Task.Result;
                                writer.WriteLine(accepted ? "ok" : "rejected");
                            } catch (Exception error) { writer.WriteLine("server-error:" + error.GetType().Name); }
                        }
                    }
                } catch (Exception) { Thread.Sleep(250); /* A malformed or abandoned request cannot close the viewer. */ }
            }
        });
        worker.IsBackground = true;
        worker.Start();
    }
}

sealed class ProjectBinding {
    internal readonly string Name;
    internal readonly string VmName;
    internal ProjectBinding(string name, string vmName) { Name = name; VmName = vmName; }
    public override string ToString() { return Name; }
}

sealed class ConfigurationChangedException : InvalidOperationException {
    internal ConfigurationChangedException() : base("Configuration changed; reopen the viewer.") { }
}

sealed class ConfigurationSnapshot {
    internal readonly string Path;
    internal readonly byte[] Hash;
    internal readonly List<ProjectBinding> Bindings;

    internal ConfigurationSnapshot(string path, byte[] hash, List<ProjectBinding> bindings) {
        Path = path; Hash = hash; Bindings = bindings;
    }

    internal FileStream OpenVerified() {
        FileStream stream = null;
        try {
            stream = new FileStream(Path, FileMode.Open, FileAccess.Read, FileShare.Read);
            if (stream.Length <= 0 || stream.Length > ViewerConfiguration.MaxConfigBytes)
                throw new ConfigurationChangedException();
            byte[] actual;
            using (SHA256 algorithm = SHA256.Create()) actual = algorithm.ComputeHash(stream);
            if (!SameBytes(Hash, actual)) throw new ConfigurationChangedException();
            stream.Position = 0;
            return stream;
        } catch (ConfigurationChangedException) {
            if (stream != null) stream.Dispose();
            throw;
        } catch {
            if (stream != null) stream.Dispose();
            throw new ConfigurationChangedException();
        }
    }

    static bool SameBytes(byte[] left, byte[] right) {
        if (left == null || right == null || left.Length != right.Length) return false;
        int difference = 0;
        for (int index = 0; index < left.Length; index++) difference |= left[index] ^ right[index];
        return difference == 0;
    }
}

static class ViewerConfiguration {
    internal const int MaxConfigBytes = 64 * 1024;
    static readonly Regex ProjectName = new Regex("\\A[a-z0-9][a-z0-9_-]{0,39}\\z", RegexOptions.CultureInvariant);
    static readonly Regex VmName = new Regex("\\A[A-Za-z0-9][A-Za-z0-9_-]{0,39}\\z", RegexOptions.CultureInvariant);

    internal static ConfigurationSnapshot Load(string path) {
        byte[] content;
        using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read)) {
            if (stream.Length <= 0 || stream.Length > MaxConfigBytes) throw new InvalidDataException("Config must be 1..65536 bytes.");
            content = new byte[(int)stream.Length];
            int offset = 0;
            while (offset < content.Length) {
                int count = stream.Read(content, offset, content.Length - offset);
                if (count == 0) throw new EndOfStreamException("Config changed while being read.");
                offset += count;
            }
        }
        byte[] hash;
        using (SHA256 algorithm = SHA256.Create()) hash = algorithm.ComputeHash(content);
        int start = content.Length >= 3 && content[0] == 0xEF && content[1] == 0xBB && content[2] == 0xBF ? 3 : 0;
        string text = new UTF8Encoding(false, true).GetString(content, start, content.Length - start);
        JavaScriptSerializer json = new JavaScriptSerializer();
        Dictionary<string, object> root = json.Deserialize<Dictionary<string, object>>(text);
        if (root == null || !root.ContainsKey("schema_version") || Convert.ToInt32(root["schema_version"]) != 1)
            throw new InvalidDataException("Expected config schema_version=1.");
        Dictionary<string, object> projects = AsDictionary(root.ContainsKey("projects") ? root["projects"] : null);
        if (projects == null || projects.Count == 0 || projects.Count > 8) throw new InvalidDataException("Expected 1..8 projects.");

        List<ProjectBinding> bindings = new List<ProjectBinding>();
        foreach (KeyValuePair<string, object> pair in projects) {
            if (!ProjectName.IsMatch(pair.Key)) throw new InvalidDataException("Invalid project name.");
            Dictionary<string, object> item = AsDictionary(pair.Value);
            if (item == null || !item.ContainsKey("vm_id") || !item.ContainsKey("bios_uuid") || !item.ContainsKey("token_file"))
                throw new InvalidDataException("Incomplete project binding.");
            Guid vmId, biosId;
            string vmIdText = item["vm_id"] as string;
            string biosIdText = item["bios_uuid"] as string;
            string tokenFile = item["token_file"] as string;
            if (!Guid.TryParse(vmIdText, out vmId) || vmId == Guid.Empty ||
                !Guid.TryParse(biosIdText, out biosId) || biosId == Guid.Empty ||
                String.IsNullOrWhiteSpace(tokenFile))
                throw new InvalidDataException("Invalid project binding.");
            string vmName = null;
            if (item.ContainsKey("vm_name")) {
                vmName = item["vm_name"] as string;
                if (vmName == null || !VmName.IsMatch(vmName)) throw new InvalidDataException("Invalid optional vm_name.");
            }
            bindings.Add(new ProjectBinding(pair.Key, vmName));
        }
        bindings.Sort(delegate(ProjectBinding left, ProjectBinding right) {
            return StringComparer.Ordinal.Compare(left.Name, right.Name);
        });
        return new ConfigurationSnapshot(path, hash, bindings);
    }

    internal static Dictionary<string, object> AsDictionary(object value) {
        return value as Dictionary<string, object>;
    }
}

sealed class HostCli {
    const int TimeoutMilliseconds = 20000;
    const int MaxStdoutCharacters = 1024 * 1024;
    readonly string python;
    readonly ConfigurationSnapshot configuration;
    readonly string workingDirectory;
    readonly JavaScriptSerializer json = new JavaScriptSerializer();

    internal HostCli(string pythonPath, ConfigurationSnapshot configuration, string workingDirectory) {
        python = pythonPath;
        this.configuration = configuration;
        this.workingDirectory = workingDirectory;
    }

    internal Task<Dictionary<string, object>> RunAsync(string project, string command, string outputPath) {
        return RunAsync(project, command, outputPath, null);
    }

    internal Task<Dictionary<string, object>> RunAsync(string project, string command, string outputPath, IEnumerable<string> extraArguments) {
        return Task.Run(delegate {
            using (FileStream configLease = configuration.OpenVerified()) {
            List<string> arguments = new List<string> { "-B", "-m", "host.client", "--config", configuration.Path, "--project", project, command };
            if (outputPath != null) { arguments.Add("--out"); arguments.Add(outputPath); }
            if (extraArguments != null) arguments.AddRange(extraArguments);
            ProcessStartInfo start = new ProcessStartInfo {
                FileName = python,
                Arguments = JoinArguments(arguments),
                WorkingDirectory = workingDirectory,
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };
            StringBuilder stdout = new StringBuilder();
            bool overflow = false;
            object gate = new object();
            using (Process process = new Process()) {
                process.StartInfo = start;
                process.OutputDataReceived += delegate(object sender, DataReceivedEventArgs e) {
                    if (e.Data == null) return;
                    lock (gate) {
                        if (stdout.Length + e.Data.Length + 1 > MaxStdoutCharacters) overflow = true;
                        else stdout.AppendLine(e.Data);
                    }
                };
                process.ErrorDataReceived += delegate { /* Deliberately discard stderr. */ };
                if (!process.Start()) throw new InvalidOperationException("Host CLI failed to start.");
                process.BeginOutputReadLine();
                process.BeginErrorReadLine();
                if (!process.WaitForExit(TimeoutMilliseconds)) {
                    try { process.Kill(); } catch { }
                    process.WaitForExit();
                    throw new TimeoutException("Host CLI timed out.");
                }
                process.WaitForExit();
                if (process.ExitCode != 0 || overflow) throw new InvalidOperationException("Windows guest operation failed.");
            }
            string body;
            lock (gate) { body = stdout.ToString().Trim(); }
            Dictionary<string, object> envelope = json.Deserialize<Dictionary<string, object>>(body);
            if (envelope == null || !envelope.ContainsKey("ok") || !(envelope["ok"] is bool) || !(bool)envelope["ok"])
                throw new InvalidDataException("Invalid Host CLI response.");
            Dictionary<string, object> result = ViewerConfiguration.AsDictionary(envelope.ContainsKey("result") ? envelope["result"] : null);
            if (result == null) throw new InvalidDataException("Missing Host CLI result.");
            return result;
            }
        });
    }

    internal static string JoinArguments(IEnumerable<string> arguments) {
        StringBuilder result = new StringBuilder();
        foreach (string argument in arguments) {
            if (result.Length > 0) result.Append(' ');
            result.Append(Quote(argument));
        }
        return result.ToString();
    }

    internal static string Quote(string value) {
        if (value == null) throw new ArgumentNullException("value");
        StringBuilder result = new StringBuilder("\"");
        int slashes = 0;
        foreach (char character in value) {
            if (character == '\\') { slashes++; continue; }
            if (character == '"') {
                result.Append('\\', slashes * 2 + 1);
                result.Append('"');
            } else {
                result.Append('\\', slashes);
                result.Append(character);
            }
            slashes = 0;
        }
        result.Append('\\', slashes * 2);
        result.Append('"');
        return result.ToString();
    }
}

static class ViewerPalette {
    internal static readonly Color Ink = Color.FromArgb(24, 32, 48);
    internal static readonly Color Muted = Color.FromArgb(102, 112, 133);
    internal static readonly Color Surface = Color.White;
    internal static readonly Color Canvas = Color.FromArgb(20, 25, 36);
    internal static readonly Color Background = Color.FromArgb(244, 247, 252);
    internal static readonly Color Accent = Color.FromArgb(55, 103, 243);
    internal static readonly Color AccentSoft = Color.FromArgb(232, 238, 255);
    internal static readonly Color Success = Color.FromArgb(28, 146, 93);
    internal static readonly Color Warning = Color.FromArgb(215, 139, 30);
    internal static readonly Color Danger = Color.FromArgb(204, 73, 73);
}

static class ViewerLayout {
    internal const int ControlHeight = 38;
    internal const int Gap = 10;

    internal static int ShortcutProjectIndex(int number, int projectCount) {
        if (number == 1) return -1;
        int index = number - 2;
        return index >= 0 && index < projectCount ? index : -2;
    }

    internal static Point MapPoint(Rectangle imageArea, int remoteWidth, int remoteHeight, Point point) {
        if (remoteWidth <= 0 || remoteHeight <= 0 || !imageArea.Contains(point)) return new Point(-1, -1);
        int x = (int)((long)(point.X - imageArea.Left) * remoteWidth / Math.Max(1, imageArea.Width));
        int y = (int)((long)(point.Y - imageArea.Top) * remoteHeight / Math.Max(1, imageArea.Height));
        return new Point(Math.Min(remoteWidth - 1, x), Math.Min(remoteHeight - 1, y));
    }

    internal static bool SelfTest() {
        Rectangle area = new Rectangle(100, 50, 800, 600);
        return ShortcutProjectIndex(1, 8) == -1 && ShortcutProjectIndex(2, 8) == 0 &&
            ShortcutProjectIndex(9, 8) == 7 && ShortcutProjectIndex(9, 7) == -2 &&
            MapPoint(area, 1600, 1200, new Point(500, 350)) == new Point(800, 600) &&
            MapPoint(area, 1600, 1200, new Point(50, 50)) == new Point(-1, -1);
    }
}

sealed class RemotePointEventArgs : EventArgs {
    internal readonly int X;
    internal readonly int Y;
    internal readonly int Button;
    internal RemotePointEventArgs(int x, int y, int button) { X = x; Y = y; Button = button; }
}

sealed class RemoteKeyEventArgs : EventArgs {
    internal readonly string KeyName;
    internal RemoteKeyEventArgs(string keyName) { KeyName = keyName; }
}

sealed class RemoteTextEventArgs : EventArgs {
    internal readonly string TextValue;
    internal RemoteTextEventArgs(string value) { TextValue = value; }
}

sealed class RemoteCanvas : Control {
    Image frame;
    Image backdrop;
    int remoteWidth;
    int remoteHeight;
    string placeholderText = "正在等待频道 · 尚未显示真实桌面";
    internal bool HumanInputEnabled;
    internal event EventHandler<RemotePointEventArgs> RemoteClick;
    internal event EventHandler<RemoteKeyEventArgs> RemoteKey;
    internal event EventHandler<RemoteTextEventArgs> RemoteText;

    internal RemoteCanvas() {
        DoubleBuffered = true;
        BackColor = ViewerPalette.Canvas;
        TabStop = true;
        SetStyle(ControlStyles.Selectable | ControlStyles.UserPaint | ControlStyles.OptimizedDoubleBuffer, true);
    }

    internal void SetFrame(Image next, int width, int height) {
        Image previous = frame;
        frame = next;
        remoteWidth = width;
        remoteHeight = height;
        if (previous != null) previous.Dispose();
        Invalidate();
    }

    internal void ClearFrame() { SetFrame(null, 0, 0); }

    internal void SetPlaceholder(string value) { placeholderText = value; Invalidate(); }

    internal void LoadBackdrop(string path) {
        try {
            FileInfo info = new FileInfo(path);
            if (!info.Exists || info.Length <= 0 || info.Length > 16 * 1024 * 1024) return;
            using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read))
            using (Image source = Image.FromStream(stream, true, true)) {
                if (source.Width <= 0 || source.Height <= 0 || (long)source.Width * source.Height > 16777216) return;
                backdrop = new Bitmap(source);
            }
        } catch { }
    }

    Rectangle FrameRectangle() {
        if (frame == null || remoteWidth <= 0 || remoteHeight <= 0) return Rectangle.Empty;
        double scale = Math.Min((double)ClientSize.Width / remoteWidth, (double)ClientSize.Height / remoteHeight);
        int width = Math.Max(1, (int)Math.Round(remoteWidth * scale));
        int height = Math.Max(1, (int)Math.Round(remoteHeight * scale));
        return new Rectangle((ClientSize.Width - width) / 2, (ClientSize.Height - height) / 2, width, height);
    }

    protected override void OnPaint(PaintEventArgs e) {
        base.OnPaint(e);
        e.Graphics.Clear(ViewerPalette.Canvas);
        Rectangle area = FrameRectangle();
        if (frame != null && !area.IsEmpty) {
            e.Graphics.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
            e.Graphics.DrawImage(frame, area);
            using (Pen pen = new Pen(Color.FromArgb(65, 82, 112))) e.Graphics.DrawRectangle(pen, area.X, area.Y, area.Width - 1, area.Height - 1);
        } else {
            if (backdrop != null) {
                double scale = Math.Max((double)ClientSize.Width / backdrop.Width, (double)ClientSize.Height / backdrop.Height);
                int width = Math.Max(1, (int)Math.Ceiling(backdrop.Width * scale));
                int height = Math.Max(1, (int)Math.Ceiling(backdrop.Height * scale));
                e.Graphics.DrawImage(backdrop, new Rectangle((ClientSize.Width - width) / 2, (ClientSize.Height - height) / 2, width, height));
                using (Brush shade = new SolidBrush(Color.FromArgb(120, 8, 14, 28))) e.Graphics.FillRectangle(shade, ClientRectangle);
            }
            string message = placeholderText;
            using (Font title = new Font("Microsoft YaHei UI", 13F, FontStyle.Regular))
            using (Brush brush = new SolidBrush(Color.White)) {
                SizeF size = e.Graphics.MeasureString(message, title);
                RectangleF panel = new RectangleF((ClientSize.Width - size.Width) / 2 - 22, (ClientSize.Height - size.Height) / 2 - 14, size.Width + 44, size.Height + 28);
                using (Brush panelBrush = new SolidBrush(Color.FromArgb(175, 15, 24, 43))) e.Graphics.FillRectangle(panelBrush, panel);
                e.Graphics.DrawString(message, title, brush, (ClientSize.Width - size.Width) / 2, (ClientSize.Height - size.Height) / 2);
            }
        }
    }

    protected override void OnMouseDown(MouseEventArgs e) {
        base.OnMouseDown(e);
        if (!HumanInputEnabled) return;
        Focus();
        Point remote = ViewerLayout.MapPoint(FrameRectangle(), remoteWidth, remoteHeight, e.Location);
        if (remote.X < 0) return;
        int button = e.Button == MouseButtons.Right ? 3 : e.Button == MouseButtons.Middle ? 2 : 1;
        EventHandler<RemotePointEventArgs> handler = RemoteClick;
        if (handler != null) handler(this, new RemotePointEventArgs(remote.X, remote.Y, button));
    }

    protected override bool IsInputKey(Keys keyData) {
        Keys key = keyData & Keys.KeyCode;
        if (key == Keys.Left || key == Keys.Right || key == Keys.Up || key == Keys.Down || key == Keys.Tab) return true;
        return base.IsInputKey(keyData);
    }

    protected override void OnKeyDown(KeyEventArgs e) {
        base.OnKeyDown(e);
        if (!HumanInputEnabled) return;
        string key = null;
        if (e.Control && e.KeyCode >= Keys.A && e.KeyCode <= Keys.Z) {
            char letter = Char.ToLowerInvariant((char)e.KeyCode);
            if ("acvxzfl".IndexOf(letter) >= 0) key = "ctrl+" + letter;
        } else {
            Dictionary<Keys, string> keys = new Dictionary<Keys, string> {
                { Keys.Enter, "Return" }, { Keys.Back, "BackSpace" }, { Keys.Tab, "Tab" },
                { Keys.Escape, "Escape" }, { Keys.Delete, "Delete" }, { Keys.Left, "Left" },
                { Keys.Right, "Right" }, { Keys.Up, "Up" }, { Keys.Down, "Down" },
                { Keys.Home, "Home" }, { Keys.End, "End" }, { Keys.PageUp, "Page_Up" },
                { Keys.PageDown, "Page_Down" }, { Keys.Space, "space" }
            };
            keys.TryGetValue(e.KeyCode, out key);
        }
        if (key != null) {
            EventHandler<RemoteKeyEventArgs> handler = RemoteKey;
            if (handler != null) handler(this, new RemoteKeyEventArgs(key));
            e.Handled = true; e.SuppressKeyPress = true;
        }
    }

    protected override void OnKeyPress(KeyPressEventArgs e) {
        base.OnKeyPress(e);
        if (!HumanInputEnabled || Char.IsControl(e.KeyChar)) return;
        EventHandler<RemoteTextEventArgs> handler = RemoteText;
        if (handler != null) handler(this, new RemoteTextEventArgs(e.KeyChar.ToString()));
        e.Handled = true;
    }

    protected override void Dispose(bool disposing) {
        if (disposing) {
            if (frame != null) { frame.Dispose(); frame = null; }
            if (backdrop != null) { backdrop.Dispose(); backdrop = null; }
        }
        base.Dispose(disposing);
    }
}

static class NativeMethods {
    internal const int WM_HOTKEY = 0x0312;
    internal const uint MOD_ALT = 0x0001;
    [DllImport("user32.dll", SetLastError=true)] internal static extern bool RegisterHotKey(IntPtr window, int id, uint modifiers, uint key);
    [DllImport("user32.dll")] internal static extern bool UnregisterHotKey(IntPtr window, int id);
}

sealed class PendingInput {
    internal readonly int Generation;
    internal readonly ProjectBinding Project;
    internal readonly List<string> Arguments;
    internal PendingInput(int generation, ProjectBinding project, List<string> arguments) {
        Generation = generation; Project = project; Arguments = arguments;
    }
}

static class SetupLauncher {
    internal static string InstallRoot() { return Path.GetFullPath(Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "..", "..")); }

    internal static void Launch() {
        string root = InstallRoot();
        string script = Path.Combine(root, "Setup-WindowsChannels.ps1");
        if (!File.Exists(script)) throw new FileNotFoundException("Setup-WindowsChannels.ps1 was not found.");
        string powershell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "WindowsPowerShell", "v1.0", "powershell.exe");
        if (!File.Exists(powershell)) throw new FileNotFoundException("Windows PowerShell was not found.");
        Process.Start(new ProcessStartInfo {
            FileName = powershell,
            Arguments = HostCli.JoinArguments(new string[] { "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script }),
            WorkingDirectory = root,
            UseShellExecute = false,
            CreateNoWindow = true
        });
    }
}

sealed class ViewerForm : Form {
    readonly ConfigurationSnapshot configuration;
    HotkeyMap hotkeys;
    readonly string hotkeyStatusPath;
    readonly HostCli cli;
    readonly string workingDirectory;
    readonly Panel navigation = new Panel();
    readonly Panel header = new Panel();
    readonly Panel statusCard = new Panel();
    readonly FlowLayoutPanel actions = new FlowLayoutPanel();
    readonly Panel immersiveChrome = new Panel();
    readonly Label chromeBrand = new Label();
    readonly Label chromeActivity = new Label();
    readonly Label chromeShortcut = new Label();
    readonly TableLayoutPanel content = new TableLayoutPanel();
    readonly TableLayoutPanel inputBar = new TableLayoutPanel();
    readonly List<Button> projectButtons = new List<Button>();
    readonly Button hostButton = new Button();
    readonly Button takeover = new Button();
    readonly Button allow = new Button();
    readonly Button pause = new Button();
    readonly Button refresh = new Button();
    readonly Button viewVm = new Button();
    readonly Button hostTop = new Button();
    readonly Button settings = new Button();
    readonly Button exitFullscreen = new Button();
    readonly Button toggleControls = new Button();
    readonly Button more = new Button();
    readonly ContextMenuStrip moreMenu = new ContextMenuStrip();
    readonly Panel statusLine = new Panel();
    readonly Label hotkeyNotice = new Label();
    readonly Label channelTitle = new Label();
    readonly Label channelDetail = new Label();
    readonly Label modeBadge = new Label();
    readonly Label identityTop = new Label();
    readonly Label modeTop = new Label();
    readonly Label status = new Label();
    readonly RemoteCanvas canvas = new RemoteCanvas();
    readonly TextBox textInput = new TextBox();
    readonly Button sendText = new Button();
    readonly System.Windows.Forms.Timer refreshTimer = new System.Windows.Forms.Timer();
    readonly System.Windows.Forms.Timer inputFlushTimer = new System.Windows.Forms.Timer();
    readonly NotifyIcon tray = new NotifyIcon();
    readonly ToolStripMenuItem hotkeyWarning = new ToolStripMenuItem();
    readonly List<ToolStripMenuItem> projectTrayItems = new List<ToolStripMenuItem>();
    ToolStripMenuItem hostTrayItem;
    Label shortcutSummary;
    readonly List<int> registeredHotkeys = new List<int>();
    readonly List<string> failedHotkeys = new List<string>();
    readonly Queue<PendingInput> inputQueue = new Queue<PendingInput>();
    readonly StringBuilder directTextBuffer = new StringBuilder();
    int selectedProject = -1;
    int generation;
    int pollCount;
    bool busy;
    bool refreshPending;
    bool desktopReady;
    bool exiting;
    bool controlTransition;
    bool immersive;
    bool controlsHidden;
    readonly bool isolatedSelfTest;
    string mode = "paused";

    internal ViewerForm(ViewerOptions options, ConfigurationSnapshot configuration) {
        this.configuration = configuration;
        isolatedSelfTest = options.SelfTestPath != null;
        hotkeys = options.HotkeysFor(configuration.Bindings.Count);
        hotkeyStatusPath = options.HotkeyStatusPath;
        workingDirectory = SetupLauncher.InstallRoot();
        cli = new HostCli(options.PythonPath, configuration, workingDirectory);
        canvas.LoadBackdrop(Path.Combine(workingDirectory, "theme", "ai-space-v2.png"));
        Text = "启程 · Windows 频道";
        Icon = SystemIcons.Application;
        Font = new Font("Microsoft YaHei UI", 9F);
        BackColor = ViewerPalette.Background;
        AutoScaleMode = AutoScaleMode.Dpi;
        AutoScaleDimensions = new SizeF(96F, 96F);
        StartPosition = FormStartPosition.CenterScreen;
        MinimumSize = new Size(760, 540);
        Size = new Size(1180, 780);

        BuildHeader();
        BuildNavigation();
        BuildContent();
        Controls.Add(content); Controls.Add(navigation); Controls.Add(header);

        refreshTimer.Interval = 1800;
        refreshTimer.Tick += async delegate {
            if (selectedProject < 0 || busy || inputQueue.Count > 0) return;
            if (++pollCount % 6 == 0) await RefreshSelectedAsync(true);
            else await RefreshScreenshotAsync(false);
        };
        inputFlushTimer.Interval = 140;
        inputFlushTimer.Tick += delegate { inputFlushTimer.Stop(); FlushDirectText(); };
        BuildTray();
        FormClosing += OnViewerClosing;
    }

    internal void InitializeHidden(bool showManagement) {
        IntPtr ignored = Handle;
        refreshTimer.Start(); ShowLocal(false);
        if (showManagement) ShowManagement(true);
        if (failedHotkeys.Count > 0) status.Text = "快捷键 " + String.Join("、", failedHotkeys.ToArray()) + " 被其他应用占用；请使用托盘菜单切换。";
    }

    protected override bool ShowWithoutActivation { get { return true; } }

    void BuildHeader() {
        header.Dock = DockStyle.Top; header.Height = 76; header.BackColor = ViewerPalette.Ink;
        Label title = new Label { Text = "启程工作台", ForeColor = Color.White, Font = new Font(Font.FontFamily, 18F, FontStyle.Bold), AutoSize = true, Location = new Point(24, 14) };
        Label subtitle = new Label { Text = "本机与私有 Windows 频道，一处切换", ForeColor = Color.FromArgb(180, 192, 215), AutoSize = true, Location = new Point(27, 48) };
        shortcutSummary = new Label { Text = hotkeys.HostLabel + " 本机    " + hotkeys.ChannelSummary() + " Windows", ForeColor = Color.FromArgb(200, 211, 232), AutoSize = true, Anchor = AnchorStyles.Top | AnchorStyles.Right };
        shortcutSummary.Location = new Point(760, 29);
        header.Resize += delegate { shortcutSummary.Left = Math.Max(400, header.ClientSize.Width - shortcutSummary.Width - 24); };
        header.Controls.Add(title); header.Controls.Add(subtitle); header.Controls.Add(shortcutSummary);
    }

    void BuildNavigation() {
        navigation.Dock = DockStyle.Left; navigation.Width = 220; navigation.BackColor = Color.White; navigation.Padding = new Padding(14, 18, 14, 12);
        Label label = new Label { Text = "工作位置", ForeColor = ViewerPalette.Muted, AutoSize = true, Font = new Font(Font, FontStyle.Bold), Location = new Point(18, 17) };
        navigation.Controls.Add(label);
        ConfigureNavButton(hostButton, "本机工作台     " + hotkeys.HostLabel, 48);
        hostButton.Click += delegate { ShowLocal(true); };
        navigation.Controls.Add(hostButton);
        for (int index = 0; index < configuration.Bindings.Count; index++) {
            int captured = index;
            Button button = new Button();
            string shortcut = "     " + hotkeys.ChannelLabel(index);
            ConfigureNavButton(button, "Windows 频道 " + (index + 1) + shortcut, 102 + index * 54);
            button.Click += async delegate { await SelectProjectAsync(captured, true); };
            projectButtons.Add(button); navigation.Controls.Add(button);
        }
        Label hint = new Label { Text = "关闭窗口后仍驻留托盘\r\n切换频道不会复用旧画面", ForeColor = ViewerPalette.Muted, AutoSize = true, Location = new Point(18, Math.Max(180, 116 + configuration.Bindings.Count * 54)) };
        navigation.Controls.Add(hint);
    }

    void ConfigureNavButton(Button button, string text, int top) {
        button.Text = text; button.TextAlign = ContentAlignment.MiddleLeft; button.FlatStyle = FlatStyle.Flat;
        button.FlatAppearance.BorderSize = 0; button.Location = new Point(10, top); button.Size = new Size(192, 44);
        button.Padding = new Padding(10, 0, 0, 0); button.BackColor = Color.White; button.ForeColor = ViewerPalette.Ink;
        button.Cursor = Cursors.Hand;
    }

    void BuildContent() {
        content.Dock = DockStyle.Fill; content.Padding = new Padding(22, 20, 22, 18); content.BackColor = ViewerPalette.Background;
        content.ColumnCount = 1; content.RowCount = 5;
        content.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F));
        content.RowStyles.Add(new RowStyle(SizeType.Absolute, 86F));
        content.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        content.RowStyles.Add(new RowStyle(SizeType.Percent, 100F));
        content.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        content.RowStyles.Add(new RowStyle(SizeType.AutoSize));

        statusCard.Dock = DockStyle.Fill; statusCard.BackColor = Color.White; statusCard.Margin = new Padding(0, 0, 0, 12);
        channelTitle.Text = "本机工作台"; channelTitle.Font = new Font(Font.FontFamily, 15F, FontStyle.Bold); channelTitle.ForeColor = ViewerPalette.Ink; channelTitle.AutoSize = true; channelTitle.Location = new Point(18, 13);
        channelDetail.Text = "当前在宿主桌面"; channelDetail.ForeColor = ViewerPalette.Muted; channelDetail.AutoSize = true; channelDetail.Location = new Point(20, 48);
        modeBadge.AutoSize = true; modeBadge.Padding = new Padding(11, 6, 11, 6); modeBadge.Font = new Font(Font, FontStyle.Bold); modeBadge.Anchor = AnchorStyles.Top | AnchorStyles.Right; modeBadge.Location = new Point(680, 22);
        statusCard.Resize += delegate { modeBadge.Left = Math.Max(400, statusCard.ClientSize.Width - modeBadge.Width - 18); };
        statusCard.Controls.Add(channelTitle); statusCard.Controls.Add(channelDetail); statusCard.Controls.Add(modeBadge);

        actions.AutoSize = true; actions.AutoSizeMode = AutoSizeMode.GrowAndShrink; actions.Dock = DockStyle.Fill; actions.WrapContents = true; actions.Margin = new Padding(0, 0, 0, 10);
        actions.Resize += delegate { UpdateImmersiveIdentity(); };
        immersiveChrome.Dock = DockStyle.Fill; immersiveChrome.BackColor = Color.FromArgb(15, 21, 32); immersiveChrome.Margin = Padding.Empty;
        immersiveChrome.Resize += delegate { LayoutImmersiveChrome(); };
        chromeBrand.Text = "启程  /  AI 工作空间"; chromeBrand.ForeColor = Color.FromArgb(227, 236, 249);
        chromeBrand.Font = new Font(Font.FontFamily, 9F, FontStyle.Bold); chromeBrand.TextAlign = ContentAlignment.MiddleLeft; chromeBrand.AutoEllipsis = true;
        chromeActivity.ForeColor = Color.FromArgb(218, 229, 244); chromeActivity.TextAlign = ContentAlignment.BottomRight; chromeActivity.AutoEllipsis = true;
        chromeShortcut.ForeColor = Color.FromArgb(139, 157, 181); chromeShortcut.TextAlign = ContentAlignment.TopRight; chromeShortcut.AutoEllipsis = true;
        immersiveChrome.Controls.Add(chromeBrand); immersiveChrome.Controls.Add(chromeActivity); immersiveChrome.Controls.Add(chromeShortcut);
        ConfigureAction(hostTop, "返回本机", Color.White, ViewerPalette.Ink, delegate { ShowLocal(true); });
        ConfigureAction(takeover, "人接管", ViewerPalette.Accent, Color.White, async delegate { await ControlAsync("takeover"); });
        ConfigureAction(allow, "交给 AI", Color.White, ViewerPalette.Accent, async delegate { await ControlAsync("allow"); });
        ConfigureAction(pause, "暂停", Color.White, ViewerPalette.Danger, async delegate { await ControlAsync("pause"); });
        ConfigureAction(refresh, "立即刷新", Color.White, ViewerPalette.Ink, async delegate { await RefreshSelectedAsync(true); });
        ConfigureAction(settings, "设置", Color.White, ViewerPalette.Muted, delegate { LaunchSetup(); });
        ConfigureAction(viewVm, "故障登录", Color.White, ViewerPalette.Muted, delegate { LaunchVmConnect(); });
        ConfigureAction(toggleControls, "隐藏控制栏", Color.White, ViewerPalette.Muted, delegate { HideImmersiveControls(); });
        ConfigureAction(exitFullscreen, "退出全屏", Color.White, ViewerPalette.Muted, delegate { ShowManagement(true); });
        ConfigureAction(more, "更多  ···", Color.White, ViewerPalette.Ink, delegate { moreMenu.Show(more, new Point(0, more.Height)); });
        moreMenu.Items.Add("立即刷新", null, async delegate { await RefreshSelectedAsync(true); });
        moreMenu.Items.Add("故障登录", null, delegate { LaunchVmConnect(); });
        moreMenu.Items.Add(new ToolStripSeparator());
        moreMenu.Items.Add("隐藏控制栏  Esc 恢复", null, delegate { HideImmersiveControls(); });
        moreMenu.Items.Add("设置与管理", null, delegate { ShowManagement(true); });
        moreMenu.Items.Add("运行设置", null, delegate { LaunchSetup(); });
        moreMenu.Items.Add("退出全屏", null, delegate { ShowManagement(true); });
        moreMenu.Opening += delegate {
            moreMenu.Items[1].Enabled = SelectedProject != null && SelectedProject.VmName != null && !busy;
            moreMenu.Items[5].Enabled = !busy;
        };
        ConfigureTopLabel(identityTop); ConfigureTopLabel(modeTop);
        actions.Controls.Add(hostTop); actions.Controls.Add(identityTop); actions.Controls.Add(modeTop); actions.Controls.Add(takeover); actions.Controls.Add(allow); actions.Controls.Add(pause);
        actions.Controls.Add(refresh); actions.Controls.Add(settings); actions.Controls.Add(viewVm); actions.Controls.Add(toggleControls); actions.Controls.Add(exitFullscreen); actions.Controls.Add(more);

        canvas.Dock = DockStyle.Fill; canvas.Margin = Padding.Empty;
        canvas.RemoteClick += delegate(object sender, RemotePointEventArgs e) { FlushDirectText(); QueueHumanInput(new string[] { "--actor", "human", "--action", "click", "--x", e.X.ToString(), "--y", e.Y.ToString(), "--button", e.Button.ToString() }); };
        canvas.RemoteKey += delegate(object sender, RemoteKeyEventArgs e) { FlushDirectText(); QueueHumanInput(new string[] { "--actor", "human", "--action", "key", "--key", e.KeyName }); };
        canvas.RemoteText += delegate(object sender, RemoteTextEventArgs e) {
            if (directTextBuffer.Length + e.TextValue.Length <= 2000) directTextBuffer.Append(e.TextValue);
            inputFlushTimer.Stop(); inputFlushTimer.Start();
        };

        inputBar.Dock = DockStyle.Fill; inputBar.AutoSize = true; inputBar.ColumnCount = 2; inputBar.Margin = new Padding(0, 10, 0, 6);
        inputBar.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100F)); inputBar.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        textInput.Dock = DockStyle.Fill; textInput.Font = new Font(Font.FontFamily, 10F); textInput.Margin = new Padding(0, 0, 10, 0); textInput.MaxLength = 2000;
        textInput.KeyDown += delegate(object sender, KeyEventArgs e) { if (e.Control && e.KeyCode == Keys.Enter) { SendTypedText(); e.SuppressKeyPress = true; } };
        textInput.TextChanged += delegate { UpdateButtons(); };
        ConfigureAction(sendText, "发送文字  Ctrl+Enter", ViewerPalette.Accent, Color.White, delegate { SendTypedText(); });
        sendText.Margin = Padding.Empty;
        inputBar.Controls.Add(textInput, 0, 0); inputBar.Controls.Add(sendText, 1, 0);

        statusLine.Dock = DockStyle.Fill; statusLine.Height = 24; statusLine.Margin = Padding.Empty;
        status.AutoEllipsis = true; status.Dock = DockStyle.Fill; status.TextAlign = ContentAlignment.MiddleLeft; status.ForeColor = ViewerPalette.Muted; status.Margin = Padding.Empty; status.Text = "就绪";
        status.TextChanged += delegate { UpdateStatusPresentation(); };
        hotkeyNotice.AutoSize = true; hotkeyNotice.Dock = DockStyle.Right; hotkeyNotice.TextAlign = ContentAlignment.MiddleRight; hotkeyNotice.ForeColor = ViewerPalette.Danger; hotkeyNotice.Visible = false;
        statusLine.Controls.Add(status); statusLine.Controls.Add(hotkeyNotice);
        content.Controls.Add(statusCard, 0, 0); content.Controls.Add(actions, 0, 1); content.Controls.Add(canvas, 0, 2); content.Controls.Add(inputBar, 0, 3); content.Controls.Add(statusLine, 0, 4);
    }

    void ConfigureAction(Button button, string text, Color back, Color fore, EventHandler click) {
        button.Text = text; button.AutoSize = true; button.AutoSizeMode = AutoSizeMode.GrowAndShrink; button.MinimumSize = new Size(104, ViewerLayout.ControlHeight);
        button.Padding = new Padding(10, 2, 10, 2); button.Margin = new Padding(0, 0, ViewerLayout.Gap, ViewerLayout.Gap);
        button.FlatStyle = FlatStyle.Flat; button.FlatAppearance.BorderColor = Color.FromArgb(220, 225, 235); button.FlatAppearance.BorderSize = back == Color.White ? 1 : 0;
        button.BackColor = back; button.ForeColor = fore; button.Cursor = Cursors.Hand; button.Click += click;
    }

    void ConfigureTopLabel(Label label) {
        label.AutoSize = true; label.MinimumSize = new Size(112, ViewerLayout.ControlHeight); label.TextAlign = ContentAlignment.MiddleCenter;
        label.Padding = new Padding(12, 10, 12, 8); label.Margin = new Padding(0, 0, ViewerLayout.Gap, ViewerLayout.Gap);
        label.Font = new Font(Font, FontStyle.Bold); label.ForeColor = Color.White;
    }

    void BuildTray() {
        ContextMenuStrip menu = new ContextMenuStrip();
        menu.Items.Add("设置与管理", null, delegate { ShowManagement(true); });
        hostTrayItem = (ToolStripMenuItem)menu.Items.Add("返回本机  " + hotkeys.HostLabel, null, delegate { ShowLocal(true); });
        for (int index = 0; index < configuration.Bindings.Count; index++) {
            int captured = index;
            string shortcut = "  " + hotkeys.ChannelLabel(index);
            projectTrayItems.Add((ToolStripMenuItem)menu.Items.Add("Windows 频道 " + (index + 1) + shortcut, null, async delegate { await SelectProjectAsync(captured, true); }));
        }
        hotkeyWarning.Enabled = false; hotkeyWarning.Visible = false;
        menu.Items.Add(hotkeyWarning);
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("运行设置", null, delegate { LaunchSetup(); });
        menu.Items.Add("退出", null, delegate { exiting = true; Close(); });
        tray.Icon = SystemIcons.Application; tray.Text = "启程 · Windows 频道"; tray.Visible = !isolatedSelfTest; tray.ContextMenuStrip = menu;
        tray.DoubleClick += delegate { ShowManagement(true); };
    }

    protected override void OnHandleCreated(EventArgs e) {
        base.OnHandleCreated(e);
        if (!isolatedSelfTest) RegisterShortcuts();
    }

    void RegisterShortcuts() {
        registeredHotkeys.Clear(); failedHotkeys.Clear();
        if (hotkeys.HostEnabled) RegisterShortcut(101, 1);
        for (int index = 0; index < hotkeys.Channels.Length; index++) RegisterShortcut(200 + index, hotkeys.Channels[index]);
        hotkeyWarning.Text = failedHotkeys.Count == 0 ? "" : "快捷键被占用：" + String.Join("、", failedHotkeys.ToArray()) + "（请用菜单切换）";
        hotkeyWarning.Visible = failedHotkeys.Count > 0;
        hotkeyNotice.Text = failedHotkeys.Count == 0 ? "" : "快捷键冲突 " + String.Join("、", failedHotkeys.ToArray()) + " · 托盘可切换";
        hotkeyNotice.Tag = hotkeyWarning.Text;
        hotkeyNotice.Visible = failedHotkeys.Count > 0;
        UpdateStatusPresentation();
        WriteHotkeyStatus(hotkeyStatusPath);
    }

    void WriteHotkeyStatus(string path) {
        if (path != null) {
            try {
                var report = new {
                    process_id = Process.GetCurrentProcess().Id,
                    host_enabled = hotkeys.HostEnabled,
                    channels = hotkeys.Channels,
                    registered = registeredHotkeys.Count,
                    failed = failedHotkeys.ToArray(),
                    checked_at = DateTime.UtcNow.ToString("o")
                };
                File.WriteAllText(path, new JavaScriptSerializer().Serialize(report), new UTF8Encoding(false));
            } catch (IOException) { /* Diagnostic output must not block switching. */ }
            catch (UnauthorizedAccessException) { /* Diagnostic output must not block switching. */ }
        }
    }

    internal bool ApplyRequest(ViewerRequest request) {
        // Lite can return both viewers to the host without knowing this viewer's private configuration.
        // The pipe itself only grants access to the current Windows user.
        if (request != null && request.ReturnToHost) { ShowLocal(true); return true; }
        if (request == null || !String.Equals(request.ConfigPath, configuration.Path, StringComparison.OrdinalIgnoreCase) ||
            request.Channels == null || request.Channels.Length != configuration.Bindings.Count) return false;
        HashSet<int> digits = new HashSet<int>();
        foreach (int digit in request.Channels) if (digit < 1 || digit > 9 || !digits.Add(digit)) return false;
        if (request.HostEnabled && digits.Contains(1)) return false;
        if (request.StatusPath != null && (!Path.IsPathRooted(request.StatusPath) || !Directory.Exists(Path.GetDirectoryName(request.StatusPath)))) return false;
        try { using (FileStream current = configuration.OpenVerified()) { } }
        catch (ConfigurationChangedException) { return false; }
        HotkeyMap previous = hotkeys;
        foreach (int id in registeredHotkeys) NativeMethods.UnregisterHotKey(Handle, id);
        hotkeys = new HotkeyMap(request.HostEnabled, request.Channels);
        RegisterShortcuts();
        if (failedHotkeys.Count > 0) {
            foreach (int id in registeredHotkeys) NativeMethods.UnregisterHotKey(Handle, id);
            hotkeys = previous;
            RegisterShortcuts();
            return false;
        }
        shortcutSummary.Text = hotkeys.HostLabel + " 本机    " + hotkeys.ChannelSummary() + " Windows";
        hostButton.Text = "本机工作台     " + hotkeys.HostLabel;
        hostTrayItem.Text = "返回本机  " + hotkeys.HostLabel;
        for (int index = 0; index < projectButtons.Count; index++) {
            projectButtons[index].Text = "Windows 频道 " + (index + 1) + "     " + hotkeys.ChannelLabel(index);
            projectTrayItems[index].Text = "Windows 频道 " + (index + 1) + "  " + hotkeys.ChannelLabel(index);
        }
        if (selectedProject < 0) channelDetail.Text = hotkeys.ChannelSummary() + " 进入独立 Windows 频道";
        UpdateStatusPresentation();
        WriteHotkeyStatus(request.StatusPath);
        if (request.Show) ShowManagement(true);
        return true;
    }

    // A hidden form and a random test-scoped pipe exercise the real receiver without a VM or visible shell.
    internal bool SelfTestHostReturnPipe() {
        int before = generation;
        ViewerControl.Serve(this);
        Task<string> rejected = SendSelfTestRequest("{\"ReturnToHost\":false}");
        if (!PumpSelfTestReply(rejected) || rejected.Result != "rejected" || generation != before) return false;
        Task<string> accepted = SendSelfTestRequest("{\"ReturnToHost\":true}");
        return PumpSelfTestReply(accepted) && accepted.Result == "ok" &&
            generation == before + 1 && selectedProject == -1 && !Visible &&
            status.Text.StartsWith("已返回本机工作台", StringComparison.Ordinal);
    }

    static Task<string> SendSelfTestRequest(string payload) {
        return Task.Factory.StartNew(delegate() {
            using (NamedPipeClientStream pipe = new NamedPipeClientStream(".", ViewerControl.PipeName, PipeDirection.InOut)) {
                pipe.Connect(1000);
                using (StreamReader reader = new StreamReader(pipe, Encoding.UTF8))
                using (StreamWriter writer = new StreamWriter(pipe, new UTF8Encoding(false)) { AutoFlush = true }) {
                    writer.WriteLine(payload);
                    return reader.ReadLine();
                }
            }
        });
    }

    static bool PumpSelfTestReply(Task response) {
        Stopwatch deadline = Stopwatch.StartNew();
        while (!response.IsCompleted && deadline.ElapsedMilliseconds < 2500) {
            Application.DoEvents();
            Thread.Sleep(5);
        }
        return response.IsCompleted && !response.IsFaulted;
    }

    void RegisterShortcut(int id, int digit) {
        if (NativeMethods.RegisterHotKey(Handle, id, NativeMethods.MOD_ALT, (uint)(Keys.D0 + digit))) registeredHotkeys.Add(id);
        else failedHotkeys.Add("Alt+" + digit);
    }

    protected override void OnHandleDestroyed(EventArgs e) {
        foreach (int id in registeredHotkeys) NativeMethods.UnregisterHotKey(Handle, id);
        registeredHotkeys.Clear();
        base.OnHandleDestroyed(e);
    }

    protected override void WndProc(ref Message message) {
        if (message.Msg == NativeMethods.WM_HOTKEY) {
            int id = message.WParam.ToInt32();
            if (hotkeys.HostEnabled && id == 101) { ShowLocal(true); return; }
            int project = id - 200;
            if (project >= 0 && project < hotkeys.Channels.Length) {
                BeginInvoke(new Action(async delegate { await SelectProjectAsync(project, true); }));
                return;
            }
        }
        base.WndProc(ref message);
    }

    internal void RequestShow() {
        if (!IsHandleCreated || IsDisposed) return;
        BeginInvoke(new Action(delegate { ShowManagement(true); }));
    }

    void ShowShell(bool activate) {
        if (!Visible) Show();
        if (WindowState == FormWindowState.Minimized) WindowState = FormWindowState.Normal;
        if (activate) { Activate(); BringToFront(); }
    }

    void ShowManagement(bool activate) {
        immersive = false; controlsHidden = false;
        FormBorderStyle = FormBorderStyle.Sizable; WindowState = FormWindowState.Normal;
        header.Visible = true; navigation.Visible = true; statusCard.Visible = true;
        if (actions.Parent == immersiveChrome) {
            immersiveChrome.Controls.Remove(actions);
            content.Controls.Remove(immersiveChrome);
            content.Controls.Add(actions, 0, 1);
        }
        actions.Visible = true; statusLine.Visible = true;
        SetAuxiliaryRowsVisible(true);
        content.RowStyles[1].SizeType = SizeType.AutoSize;
        content.Padding = new Padding(22, 20, 22, 18);
        content.RowStyles[0].Height = 86F;
        content.BackColor = ViewerPalette.Background;
        actions.AutoSize = true; actions.Dock = DockStyle.Fill; actions.BackColor = ViewerPalette.Background; actions.WrapContents = true; actions.Padding = Padding.Empty; actions.Margin = new Padding(0, 0, 0, 10);
        SetActionAppearance(hostTop, Color.White, ViewerPalette.Ink);
        SetActionAppearance(takeover, ViewerPalette.Accent, Color.White);
        SetActionAppearance(allow, Color.White, ViewerPalette.Accent);
        SetActionAppearance(pause, Color.White, ViewerPalette.Danger);
        statusLine.BackColor = ViewerPalette.Background; status.ForeColor = ViewerPalette.Muted;
        foreach (Control control in actions.Controls) control.Margin = new Padding(0, 0, ViewerLayout.Gap, ViewerLayout.Gap);
        identityTop.MinimumSize = modeTop.MinimumSize = new Size(112, ViewerLayout.ControlHeight);
        identityTop.MaximumSize = modeTop.MaximumSize = Size.Empty;
        hostTop.Visible = false; exitFullscreen.Visible = false; toggleControls.Visible = false;
        more.Visible = false; refresh.Visible = SelectedProject != null; settings.Visible = true;
        ProjectBinding project = SelectedProject;
        viewVm.Visible = project != null && project.VmName != null;
        ShowShell(activate); UpdateButtons(); UpdateStatusPresentation();
    }

    void EnterImmersive(bool activate) {
        immersive = true; controlsHidden = false;
        FormBorderStyle = FormBorderStyle.None; WindowState = FormWindowState.Maximized;
        header.Visible = false; navigation.Visible = false; statusCard.Visible = false;
        if (actions.Parent == content) {
            content.Controls.Remove(actions);
            immersiveChrome.Controls.Add(actions);
            content.Controls.Add(immersiveChrome, 0, 1);
        }
        immersiveChrome.Visible = true; actions.Visible = true; statusLine.Visible = true;
        SetAuxiliaryRowsVisible(true);
        content.RowStyles[1].SizeType = SizeType.Absolute; content.RowStyles[1].Height = 52F;
        content.Padding = Padding.Empty; content.BackColor = ViewerPalette.Canvas;
        content.RowStyles[0].Height = 0F;
        actions.AutoSize = false; actions.Dock = DockStyle.None;
        actions.BackColor = Color.FromArgb(15, 21, 32); actions.WrapContents = false;
        actions.Padding = new Padding(14, 4, 14, 4); actions.Margin = Padding.Empty;
        foreach (Control control in actions.Controls) control.Margin = new Padding(0, 0, 8, 0);
        SetActionAppearance(hostTop, Color.FromArgb(34, 43, 59), Color.FromArgb(224, 231, 242));
        SetActionAppearance(takeover, Color.FromArgb(44, 57, 75), Color.FromArgb(232, 239, 248));
        SetActionAppearance(allow, Color.FromArgb(44, 57, 75), Color.FromArgb(232, 239, 248));
        SetActionAppearance(pause, Color.FromArgb(44, 57, 75), Color.FromArgb(232, 239, 248));
        SetActionAppearance(more, Color.FromArgb(34, 43, 59), Color.FromArgb(224, 231, 242));
        identityTop.MinimumSize = modeTop.MinimumSize = Size.Empty;
        identityTop.MaximumSize = new Size(220, ViewerLayout.ControlHeight);
        modeTop.MaximumSize = new Size(130, ViewerLayout.ControlHeight);
        identityTop.AutoEllipsis = true; modeTop.AutoEllipsis = true;
        identityTop.Padding = modeTop.Padding = new Padding(10, 7, 10, 6);
        statusLine.BackColor = Color.FromArgb(15, 21, 32); status.ForeColor = Color.FromArgb(178, 191, 209);
        hostTop.Visible = true; exitFullscreen.Visible = false; toggleControls.Visible = false;
        refresh.Visible = false; viewVm.Visible = false; settings.Visible = false; more.Visible = true;
        LayoutImmersiveChrome();
        UpdateImmersiveIdentity();
        ShowShell(activate); UpdateButtons(); UpdateStatusPresentation();
    }

    void LayoutImmersiveChrome() {
        if (!immersive) return;
        int width = immersiveChrome.ClientSize.Width;
        int height = immersiveChrome.ClientSize.Height;
        if (width <= 0 || height <= 0) return;
        int brandWidth = width >= 1200 ? 174 : width >= 1000 ? 104 : 0;
        int rightWidth = width >= 1200 ? 330 : width >= 900 ? 180 : 0;
        int gap = brandWidth > 0 ? 12 : 0;
        int actionsWidth = Math.Min(700, Math.Max(0, width - brandWidth - rightWidth - gap - 16));
        chromeBrand.Visible = brandWidth > 0;
        chromeBrand.Text = width < 1200 ? "启程" : "启程  /  AI 工作空间";
        chromeBrand.SetBounds(18, 0, Math.Max(0, brandWidth - 18), height);
        actions.SetBounds(brandWidth + gap, 0, actionsWidth, height);
        bool showRight = rightWidth > 0;
        chromeActivity.Visible = showRight; chromeShortcut.Visible = showRight;
        if (showRight) {
            int rightX = width - rightWidth - 18;
            chromeActivity.SetBounds(rightX, 7, rightWidth, Math.Max(15, height / 2 - 5));
            chromeShortcut.SetBounds(rightX, height / 2, rightWidth, Math.Max(15, height / 2 - 7));
        }
    }

    void UpdateImmersiveIdentity() {
        if (!immersive || selectedProject < 0) return;
        int width = actions.ClientSize.Width;
        bool narrow = width < 980;
        bool veryNarrow = width < 760;
        identityTop.Text = narrow ? "频道 " + (selectedProject + 1) :
            "频道 " + (selectedProject + 1) + " · " + SelectedProject.Name;
        identityTop.MaximumSize = new Size(veryNarrow ? 80 : narrow ? 105 : 220, ViewerLayout.ControlHeight);
        modeTop.MaximumSize = new Size(veryNarrow ? 105 : 130, ViewerLayout.ControlHeight);
        Button[] primary = { hostTop, takeover, allow, pause, more };
        foreach (Button button in primary) {
            button.MinimumSize = new Size(veryNarrow ? 60 : 72, 34);
            button.Padding = new Padding(veryNarrow ? 6 : 12, 0, veryNarrow ? 6 : 12, 0);
            button.Margin = new Padding(0, 0, veryNarrow ? 4 : 8, 0);
        }
        identityTop.Margin = modeTop.Margin = new Padding(0, 0, veryNarrow ? 4 : 8, 0);
    }

    void SetActionAppearance(Button button, Color back, Color fore) {
        button.BackColor = back; button.ForeColor = fore;
        button.FlatAppearance.BorderSize = 0;
        button.MinimumSize = new Size(immersive ? 72 : 104, immersive ? 34 : ViewerLayout.ControlHeight);
        button.Padding = immersive ? new Padding(12, 0, 12, 0) : new Padding(10, 2, 10, 2);
    }

    void HideImmersiveControls() {
        if (!immersive) return;
        controlsHidden = true; actions.Visible = false; inputBar.Visible = false;
        immersiveChrome.Visible = false;
        SetAuxiliaryRowsVisible(false);
        UpdateStatusPresentation();
        canvas.Focus();
    }

    void SetAuxiliaryRowsVisible(bool visible) {
        int[] rows = { 1, 3 };
        foreach (int row in rows) {
            content.RowStyles[row].SizeType = visible ? SizeType.AutoSize : SizeType.Absolute;
            content.RowStyles[row].Height = 0F;
        }
        content.RowStyles[4].SizeType = SizeType.Absolute;
        content.RowStyles[4].Height = immersive && !controlsHidden ? 0F : immersive ? 24F : 28F;
    }

    void UpdateStatusPresentation() {
        if (statusLine == null || content.RowStyles.Count < 5) return;
        chromeActivity.Text = status.Text;
        chromeShortcut.Text = selectedProject < 0 ? hotkeys.HostLabel + " 本机" :
            hotkeys.HostLabel + " 本机  ·  " + hotkeys.ChannelLabel(selectedProject) + " 当前频道";
        if (!immersive) { statusLine.Visible = true; content.RowStyles[4].Height = 28F; return; }
        string message = status.Text ?? "";
        bool important = !desktopReady || mode == "unknown" ||
            message.Contains("失败") || message.Contains("不可用") || message.Contains("未知") ||
            message.Contains("冲突") || message.Contains("被其他应用占用") || message.Contains("配置已变化");
        bool showFooter = controlsHidden || important || failedHotkeys.Count > 0;
        statusLine.Visible = showFooter;
        content.RowStyles[4].Height = showFooter ? 24F : 0F;
    }

    protected override bool ProcessCmdKey(ref Message message, Keys keyData) {
        if (immersive && keyData == Keys.Escape) {
            if (controlsHidden) {
                controlsHidden = false; immersiveChrome.Visible = true; actions.Visible = true;
                SetAuxiliaryRowsVisible(true); content.RowStyles[1].SizeType = SizeType.Absolute; content.RowStyles[1].Height = 52F;
                UpdateButtons(); UpdateStatusPresentation();
            }
            else ShowManagement(true);
            return true;
        }
        return base.ProcessCmdKey(ref message, keyData);
    }

    void ShowLocal(bool hide) {
        generation++; selectedProject = -1; refreshPending = false; inputQueue.Clear(); directTextBuffer.Length = 0; inputFlushTimer.Stop(); textInput.Clear(); mode = "paused"; desktopReady = false;
        canvas.SetPlaceholder("选择 Windows 频道 · 当前未显示远程桌面"); canvas.ClearFrame(); UpdateChrome(); status.Text = "已返回本机工作台；Windows 频道仍保持各自真实状态。";
        immersive = false; controlsHidden = false;
        if (hide) Hide();
    }

    async Task SelectProjectAsync(int index, bool activate) {
        if (index < 0 || index >= configuration.Bindings.Count) return;
        generation++; selectedProject = index; refreshPending = false; inputQueue.Clear(); directTextBuffer.Length = 0; inputFlushTimer.Stop(); textInput.Clear(); mode = "paused"; desktopReady = false;
        canvas.SetPlaceholder("正在连接 Windows 频道 " + (index + 1) + " · 尚未显示真实桌面"); canvas.ClearFrame(); UpdateChrome(); EnterImmersive(activate);
        await RefreshSelectedAsync(true);
    }

    ProjectBinding SelectedProject { get { return selectedProject >= 0 && selectedProject < configuration.Bindings.Count ? configuration.Bindings[selectedProject] : null; } }

    void UpdateChrome() {
        hostButton.BackColor = selectedProject < 0 ? ViewerPalette.AccentSoft : Color.White;
        hostButton.ForeColor = selectedProject < 0 ? ViewerPalette.Accent : ViewerPalette.Ink;
        for (int index = 0; index < projectButtons.Count; index++) {
            bool selected = index == selectedProject;
            projectButtons[index].BackColor = selected ? ViewerPalette.AccentSoft : Color.White;
            projectButtons[index].ForeColor = selected ? ViewerPalette.Accent : ViewerPalette.Ink;
        }
        ProjectBinding project = SelectedProject;
        if (project == null) {
            channelTitle.Text = "本机工作台"; channelDetail.Text = hotkeys.ChannelSummary() + " 进入独立 Windows 频道";
            identityTop.Text = "本机"; identityTop.BackColor = ViewerPalette.Ink;
        } else {
            channelTitle.Text = "Windows 频道 " + (selectedProject + 1);
            channelDetail.Text = project.Name + (project.VmName == null ? "" : "  ·  " + project.VmName);
            identityTop.Text = "频道 " + (selectedProject + 1) + " · " + project.Name;
            identityTop.BackColor = ProjectColor(selectedProject);
        }
        UpdateImmersiveIdentity();
        UpdateModeBadge(); UpdateButtons();
    }

    void UpdateModeBadge() {
        if (selectedProject < 0) { modeBadge.Text = "本机"; modeBadge.BackColor = ViewerPalette.AccentSoft; modeBadge.ForeColor = ViewerPalette.Accent; }
        else if (mode == "unknown") { modeBadge.Text = "状态未知"; modeBadge.BackColor = Color.FromArgb(241, 243, 248); modeBadge.ForeColor = ViewerPalette.Muted; }
        else if (!desktopReady) { modeBadge.Text = "未连接"; modeBadge.BackColor = Color.FromArgb(241, 243, 248); modeBadge.ForeColor = ViewerPalette.Muted; }
        else if (mode == "human") { modeBadge.Text = "人正在接管"; modeBadge.BackColor = Color.FromArgb(229, 247, 239); modeBadge.ForeColor = ViewerPalette.Success; }
        else if (mode == "agent") { modeBadge.Text = "AI 可操作"; modeBadge.BackColor = ViewerPalette.AccentSoft; modeBadge.ForeColor = ViewerPalette.Accent; }
        else if (mode == "paused") { modeBadge.Text = "已暂停"; modeBadge.BackColor = Color.FromArgb(255, 244, 224); modeBadge.ForeColor = ViewerPalette.Warning; }
        else { modeBadge.Text = "状态未知"; modeBadge.BackColor = Color.FromArgb(241, 243, 248); modeBadge.ForeColor = ViewerPalette.Muted; }
        modeTop.Text = modeBadge.Text; modeTop.BackColor = selectedProject < 0 ? ViewerPalette.Ink : !desktopReady ? ViewerPalette.Muted : mode == "human" ? ViewerPalette.Success : mode == "agent" ? ViewerPalette.Accent : mode == "paused" ? ViewerPalette.Warning : ViewerPalette.Muted;
        modeTop.ForeColor = Color.White;
        modeBadge.Left = Math.Max(400, statusCard.ClientSize.Width - modeBadge.Width - 18);
    }

    static Color ProjectColor(int index) {
        Color[] colors = { Color.FromArgb(43, 111, 222), Color.FromArgb(20, 145, 113), Color.FromArgb(138, 84, 210), Color.FromArgb(220, 112, 42), Color.FromArgb(29, 136, 158), Color.FromArgb(183, 66, 112), Color.FromArgb(84, 112, 60), Color.FromArgb(99, 91, 178) };
        return colors[Math.Max(0, Math.Min(colors.Length - 1, index))];
    }

    void UpdateButtons() {
        ProjectBinding project = SelectedProject;
        bool connected = project != null && desktopReady;
        takeover.Enabled = connected && !busy && mode != "human";
        allow.Enabled = connected && !busy && mode != "agent";
        pause.Enabled = connected && !busy && mode != "paused";
        refresh.Enabled = project != null && !busy;
        settings.Enabled = !busy;
        refresh.Visible = !immersive && project != null;
        viewVm.Visible = !immersive && project != null && project.VmName != null;
        viewVm.Enabled = project != null && project.VmName != null && !busy;
        hostTop.Visible = immersive;
        identityTop.Visible = immersive;
        modeTop.Visible = immersive;
        exitFullscreen.Visible = false;
        toggleControls.Visible = false;
        more.Visible = immersive;
        settings.Visible = !immersive && !busy;
        bool human = connected && mode == "human" && !controlTransition;
        canvas.HumanInputEnabled = human;
        textInput.Enabled = human;
        sendText.Enabled = human && textInput.TextLength > 0;
        inputBar.Visible = human && !controlsHidden;
        content.RowStyles[3].SizeType = inputBar.Visible ? SizeType.AutoSize : SizeType.Absolute;
        content.RowStyles[3].Height = 0F;
        takeover.BackColor = immersive && human ? Color.FromArgb(21, 112, 93) : immersive ? Color.FromArgb(44, 57, 75) : ViewerPalette.Accent;
        allow.BackColor = immersive && connected && mode == "agent" ? Color.FromArgb(46, 83, 174) : immersive ? Color.FromArgb(44, 57, 75) : Color.White;
        pause.BackColor = immersive && connected && mode == "paused" ? Color.FromArgb(113, 70, 31) : immersive ? Color.FromArgb(44, 57, 75) : Color.White;
        UpdateStatusPresentation();
    }

    bool BeginBusy(string message) {
        if (busy || SelectedProject == null) return false;
        busy = true; status.Text = message; UpdateButtons(); return true;
    }

    void EndBusy() {
        busy = false; UpdateButtons();
        if (selectedProject < 0) return;
        if (inputQueue.Count > 0) BeginInvoke(new Action(async delegate { await DrainInputAsync(); }));
        else if (refreshPending) { refreshPending = false; BeginInvoke(new Action(async delegate { await RefreshSelectedAsync(true); })); }
    }

    async Task RefreshSelectedAsync(bool includeState) {
        ProjectBinding project = SelectedProject;
        if (project == null) return;
        if (busy) { refreshPending = true; return; }
        int epoch = generation;
        refreshPending = false;
        if (!BeginBusy(includeState ? "正在连接真实频道…" : "正在刷新画面…")) return;
        try {
            if (includeState) {
                Dictionary<string, object> state = await cli.RunAsync(project.Name, "state", null);
                if (epoch != generation) return;
                ApplyState(state);
            }
            await CaptureFrameAsync(project, epoch);
        } catch (Exception exception) {
            if (epoch == generation) ShowFailure(exception, "频道暂时不可用，请稍后重试。", true);
        } finally { EndBusy(); }
    }

    async Task RefreshScreenshotAsync(bool userRequested) {
        ProjectBinding project = SelectedProject;
        if (project == null) return;
        if (busy) { if (userRequested) refreshPending = true; return; }
        int epoch = generation;
        if (!BeginBusy(userRequested ? "正在刷新真实画面…" : "正在同步画面…")) return;
        try { await CaptureFrameAsync(project, epoch); }
        catch (Exception exception) { if (epoch == generation) ShowFailure(exception, "画面刷新失败；频道已保留。", false); }
        finally { EndBusy(); }
    }

    async Task CaptureFrameAsync(ProjectBinding project, int epoch) {
        string root = Path.GetFullPath(Path.Combine(workingDirectory, ".local", "viewer"));
        Directory.CreateDirectory(root);
        string output = Path.GetFullPath(Path.Combine(root, project.Name + "-" + Guid.NewGuid().ToString("N") + ".png"));
        string prefix = root.TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar;
        if (!output.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) throw new InvalidOperationException("Unsafe screenshot path.");
        try {
            Dictionary<string, object> result = await cli.RunAsync(project.Name, "screenshot", output);
            string reported = result.ContainsKey("screenshot") ? result["screenshot"] as string : null;
            if (reported == null || !String.Equals(Path.GetFullPath(reported), output, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("Unexpected screenshot destination.");
            Bitmap image = LoadPng(output);
            int width = Convert.ToInt32(result["width"]), height = Convert.ToInt32(result["height"]);
            if (epoch == generation) { canvas.SetFrame(image, width, height); image = null; status.Text = "画面已同步 · " + DateTime.Now.ToString("HH:mm:ss"); }
            if (image != null) image.Dispose();
        } finally { try { if (File.Exists(output)) File.Delete(output); } catch { } }
    }

    async Task ControlAsync(string command) {
        ProjectBinding project = SelectedProject;
        if (project == null || busy) return;
        inputFlushTimer.Stop(); directTextBuffer.Length = 0; inputQueue.Clear(); textInput.Clear();
        controlTransition = true;
        int epoch = generation;
        if (!BeginBusy(command == "takeover" ? "正在接管频道…" : command == "allow" ? "正在交给 AI…" : "正在暂停频道…")) { controlTransition = false; return; }
        try {
            if (command == "allow" && mode == "human") await cli.RunAsync(project.Name, "pause", null);
            Dictionary<string, object> result = await cli.RunAsync(project.Name, command, null);
            if (epoch == generation) { ApplyState(result); refreshPending = true; }
        } catch (Exception exception) { if (epoch == generation) ShowFailure(exception, "状态切换失败，真实频道未被替代。", false); }
        finally { controlTransition = false; EndBusy(); }
    }

    void QueueHumanInput(IEnumerable<string> arguments) {
        ProjectBinding project = SelectedProject;
        if (project == null || !desktopReady || mode != "human" || controlTransition) { status.Text = controlTransition ? "正在切换控制权，请稍候。" : "请先点击“人接管”。"; return; }
        if (inputQueue.Count >= 32) { status.Text = "输入处理中，请稍候。"; return; }
        inputQueue.Enqueue(new PendingInput(generation, project, new List<string>(arguments)));
        status.Text = "输入已排队…";
        if (!busy) BeginInvoke(new Action(async delegate { await DrainInputAsync(); }));
    }

    async Task DrainInputAsync() {
        if (busy || inputQueue.Count == 0) return;
        PendingInput first = inputQueue.Peek();
        if (first.Generation != generation || first.Project != SelectedProject) { inputQueue.Clear(); return; }
        if (!BeginBusy("正在发送人工输入…")) return;
        try {
            bool inputFailed = false;
            try {
                while (inputQueue.Count > 0) {
                    PendingInput input = inputQueue.Dequeue();
                    if (input.Generation != generation || input.Project != SelectedProject) continue;
                    await cli.RunAsync(input.Project.Name, "input", null, input.Arguments);
                }
                if (first.Generation == generation) { status.Text = "人工输入已提交，正在更新画面…"; refreshPending = true; }
            } catch {
                inputQueue.Clear(); inputFailed = true;
            }
            if (inputFailed) await RecoverAfterInputFailureAsync(first);
        } finally { EndBusy(); }
    }

    async Task RecoverAfterInputFailureAsync(PendingInput failed) {
        try { await cli.RunAsync(failed.Project.Name, "pause", null); } catch { }
        Dictionary<string, object> recovered = null;
        try { recovered = await cli.RunAsync(failed.Project.Name, "state", null); } catch { }
        if (failed.Generation != generation || failed.Project != SelectedProject) return;
        if (recovered != null) {
            ApplyState(recovered);
            string actual = mode == "paused" ? "已暂停" : mode == "human" ? "仍由人接管" : mode == "agent" ? "仍由 AI 控制" : "未知";
            status.Text = "人工输入失败；回读确认当前状态：" + actual + "。";
        } else {
            mode = "unknown"; desktopReady = false; UpdateModeBadge(); UpdateButtons();
            status.Text = "人工输入失败；暂停和状态回读未能确认，当前真实状态未知。";
        }
    }

    void SendTypedText() {
        string value = textInput.Text;
        if (String.IsNullOrEmpty(value)) return;
        textInput.Clear();
        QueueHumanInput(new string[] { "--actor", "human", "--action", "type", "--text", value });
    }

    void FlushDirectText() {
        if (directTextBuffer.Length == 0) return;
        string value = directTextBuffer.ToString(); directTextBuffer.Length = 0;
        QueueHumanInput(new string[] { "--actor", "human", "--action", "type", "--text", value });
    }

    void ApplyState(Dictionary<string, object> result) {
        mode = result.ContainsKey("mode") ? Convert.ToString(result["mode"]) : "unknown";
        desktopReady = result.ContainsKey("desktop_ready") && result["desktop_ready"] is bool && (bool)result["desktop_ready"];
        string actionsCount = result.ContainsKey("actions") ? Convert.ToString(result["actions"]) : "?";
        status.Text = desktopReady ? "频道在线 · 已执行 " + actionsCount + " 个动作" : "频道已连接，但桌面当前不可操作";
        UpdateModeBadge(); UpdateButtons();
    }

    static Bitmap LoadPng(string path) {
        FileInfo info = new FileInfo(path);
        if (!info.Exists || info.Length < 24 || info.Length > 8 * 1024 * 1024) throw new InvalidDataException("Invalid screenshot size.");
        using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read)) {
            byte[] header = new byte[24];
            if (stream.Read(header, 0, header.Length) != header.Length || header[0] != 0x89 || header[1] != 0x50 || header[2] != 0x4E || header[3] != 0x47 || header[12] != 0x49 || header[13] != 0x48 || header[14] != 0x44 || header[15] != 0x52) throw new InvalidDataException("Invalid screenshot format.");
            int width = ReadBigEndianInt32(header, 16), height = ReadBigEndianInt32(header, 20);
            if (width <= 0 || height <= 0 || width > 16384 || height > 16384 || (long)width * height > 16777216) throw new InvalidDataException("Unsupported screenshot dimensions.");
            stream.Position = 0; using (Image source = Image.FromStream(stream, true, true)) return new Bitmap(source);
        }
    }

    static int ReadBigEndianInt32(byte[] value, int offset) { return (value[offset] << 24) | (value[offset + 1] << 16) | (value[offset + 2] << 8) | value[offset + 3]; }

    void ShowFailure(Exception exception, string fallback, bool clearFrame) {
        status.Text = exception is ConfigurationChangedException ? "配置已变化，请重新打开启程工作台。" : fallback;
        desktopReady = false; mode = "unknown"; UpdateModeBadge(); UpdateButtons();
        if (clearFrame) { canvas.SetPlaceholder("频道未就绪 · 尚未显示真实桌面"); canvas.ClearFrame(); }
    }

    void LaunchVmConnect() {
        ProjectBinding project = SelectedProject;
        if (project == null || project.VmName == null || busy) return;
        try {
            using (FileStream configLease = configuration.OpenVerified()) {
                string executable = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), "System32", "vmconnect.exe");
                if (!File.Exists(executable)) throw new FileNotFoundException();
                Process.Start(new ProcessStartInfo { FileName = executable, Arguments = HostCli.JoinArguments(new string[] { "localhost", project.VmName }), WorkingDirectory = workingDirectory, UseShellExecute = false });
                status.Text = "已打开故障登录窗口。";
            }
        } catch (Exception exception) { ShowFailure(exception, "故障登录入口不可用。", false); }
    }

    void LaunchSetup() {
        try {
            SetupLauncher.Launch();
            exiting = true; Close();
        } catch (Exception exception) { ShowFailure(exception, "未找到安装根目录中的设置程序。", false); }
    }

    void OnViewerClosing(object sender, FormClosingEventArgs e) {
        if (!exiting && e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Hide(); return; }
        refreshTimer.Stop(); tray.Visible = false;
    }

    protected override void Dispose(bool disposing) {
        if (disposing) { refreshTimer.Dispose(); inputFlushTimer.Dispose(); tray.Dispose(); }
        base.Dispose(disposing);
    }
}


static class ViewerApp {
    static void PromptForSetup() {
        DialogResult choice = MessageBox.Show(
            "尚未完成 Windows 频道设置。是否现在打开设置？",
            "启程 · 首次设置", MessageBoxButtons.YesNo, MessageBoxIcon.Information);
        if (choice != DialogResult.Yes) return;
        try { SetupLauncher.Launch(); }
        catch { MessageBox.Show("未找到安装根目录中的 Setup-WindowsChannels.ps1。", "启程 · 首次设置", MessageBoxButtons.OK, MessageBoxIcon.Error); }
    }

    static bool SelfTestChangedConfiguration(string directory) {
        string fixture = Path.Combine(directory, "viewer-config-" + Guid.NewGuid().ToString("N") + ".json");
        try {
            string body = "{\"schema_version\":1,\"projects\":{\"fixture\":{" +
                "\"vm_id\":\"11111111-1111-1111-1111-111111111111\"," +
                "\"bios_uuid\":\"22222222-2222-2222-2222-222222222222\"," +
                "\"token_file\":\"missing.token\"}}}";
            File.WriteAllText(fixture, body, new UTF8Encoding(false));
            ConfigurationSnapshot snapshot = ViewerConfiguration.Load(fixture);
            File.AppendAllText(fixture, " ", new UTF8Encoding(false));
            try {
                using (FileStream ignored = snapshot.OpenVerified()) { }
                return false;
            } catch (ConfigurationChangedException) {
                return true;
            }
        } finally {
            try { if (File.Exists(fixture)) File.Delete(fixture); } catch { }
        }
    }

    [STAThread]
    static void Main(string[] args) {
        ViewerOptions options = null;
        try {
            options = ViewerOptions.Parse(args);
            if (options.SelfTestPath != null) {
                ConfigurationSnapshot configuration = ViewerConfiguration.Load(options.ConfigPath);
                bool quoteOk = HostCli.Quote("C:\\Path With Space\\python.exe") == "\"C:\\Path With Space\\python.exe\"";
                bool changedConfigRefused = SelfTestChangedConfiguration(Path.GetDirectoryName(options.SelfTestPath));
                bool responsiveLayout = ViewerLayout.SelfTest();
                string humanArguments = HostCli.JoinArguments(new string[] { "--actor", "human", "--action", "click", "--x", "10", "--y", "20" });
                bool humanInputRouted = humanArguments.Contains("\"--actor\" \"human\"") && humanArguments.Contains("\"--action\" \"click\"");
                ViewerOptions shown = ViewerOptions.Parse(new string[] { "--config", options.ConfigPath, "--python", options.PythonPath, "--show" });
                bool showFlagParsed = shown.ShowOnStart;
                HotkeyMap activeHotkeys = options.HotkeysFor(configuration.Bindings.Count);
                bool hotkeyMapValid = activeHotkeys.Channels.Length == configuration.Bindings.Count &&
                    activeHotkeys.HostEnabled == options.HostHotkeyEnabled;
                bool duplicateRejected = false, hostConflictRejected = false, countRejected = false;
                try { ViewerOptions.Parse(new string[] { "--config", options.ConfigPath, "--python", options.PythonPath, "--channel-hotkeys", "4,4" }); }
                catch (ArgumentException) { duplicateRejected = true; }
                try { ViewerOptions.Parse(new string[] { "--config", options.ConfigPath, "--python", options.PythonPath, "--channel-hotkeys", "1" }).HotkeysFor(1); }
                catch (ArgumentException) { hostConflictRejected = true; }
                try { ViewerOptions.Parse(new string[] { "--config", options.ConfigPath, "--python", options.PythonPath, "--channel-hotkeys", "4" }).HotkeysFor(2); }
                catch (ArgumentException) { countRejected = true; }
                hotkeyMapValid = hotkeyMapValid && duplicateRejected && hostConflictRejected && countRejected;
                bool hostReturnPipe = false;
                string previousScope = Environment.GetEnvironmentVariable("QICHENG_WINDOWS_VIEWER_TEST_SCOPE");
                Environment.SetEnvironmentVariable("QICHENG_WINDOWS_VIEWER_TEST_SCOPE", Guid.NewGuid().ToString("N"));
                try {
                    using (ViewerForm hidden = new ViewerForm(options, configuration)) {
                        hidden.InitializeHidden(false);
                        hostReturnPipe = hidden.SelfTestHostReturnPipe();
                    }
                } finally { Environment.SetEnvironmentVariable("QICHENG_WINDOWS_VIEWER_TEST_SCOPE", previousScope); }
                string body = "{\"arguments_valid\":true,\"project_count\":" + configuration.Bindings.Count +
                    ",\"quoting_valid\":" + (quoteOk ? "true" : "false") +
                    ",\"changed_config_refused\":" + (changedConfigRefused ? "true" : "false") +
                    ",\"responsive_layout\":" + (responsiveLayout ? "true" : "false") +
                    ",\"human_input_routed\":" + (humanInputRouted ? "true" : "false") +
                    ",\"show_flag_parsed\":" + (showFlagParsed ? "true" : "false") +
                    ",\"host_hotkey_enabled\":" + (activeHotkeys.HostEnabled ? "true" : "false") +
                    ",\"channel_hotkeys\":[" + String.Join(",", Array.ConvertAll(activeHotkeys.Channels, x => x.ToString())) + "]" +
                    ",\"hotkey_map_valid\":" + (hotkeyMapValid ? "true" : "false") +
                    ",\"host_return_pipe\":" + (hostReturnPipe ? "true" : "false") +
                    ",\"default_hidden\":" + (!options.ShowOnStart ? "true" : "false") +
                    ",\"dynamic_hotkeys\":true,\"immersive_shell\":true" +
                    ",\"single_instance_designed\":true,\"continuous_refresh_designed\":true" +
                    ",\"cli_invoked\":false,\"gui_tested\":false}";
                File.WriteAllText(options.SelfTestPath, body, new UTF8Encoding(false));
                Environment.Exit(quoteOk && changedConfigRefused && responsiveLayout && humanInputRouted && showFlagParsed && hotkeyMapValid && hostReturnPipe ? 0 : 1);
                return;
            }
            using (EventWaitHandle activation = new EventWaitHandle(false, EventResetMode.AutoReset, ViewerInstance.ActivationName)) {
                bool created;
                using (Mutex instance = new Mutex(true, ViewerInstance.MutexName, out created)) {
                    if (!created) {
                        ConfigurationSnapshot requestedConfiguration = ViewerConfiguration.Load(options.ConfigPath);
                        ViewerControl.Send(options, options.HotkeysFor(requestedConfiguration.Bindings.Count));
                        return;
                    }
                    Application.EnableVisualStyles();
                    Application.SetCompatibleTextRenderingDefault(false);
                    if (!File.Exists(options.ConfigPath)) { PromptForSetup(); instance.ReleaseMutex(); return; }
                    ConfigurationSnapshot configuration = ViewerConfiguration.Load(options.ConfigPath);
                    ViewerForm form = new ViewerForm(options, configuration);
                    ApplicationContext context = new ApplicationContext();
                    form.FormClosed += delegate { context.ExitThread(); };
                    form.InitializeHidden(options.ShowOnStart);
                    ViewerControl.Serve(form);
                    RegisteredWaitHandle wait = ThreadPool.RegisterWaitForSingleObject(activation, delegate { form.RequestShow(); }, null, Timeout.Infinite, false);
                    try { Application.Run(context); }
                    finally { wait.Unregister(null); form.Dispose(); context.Dispose(); instance.ReleaseMutex(); }
                }
            }
        } catch (Exception exception) {
            if (Array.IndexOf(args, "--self-test") >= 0) Environment.Exit(2);
            if (options != null && options.QuietControlError && options.HotkeyStatusPath != null) {
                try {
                    var diagnostic = new {
                        status = "control-failed", process_id = Process.GetCurrentProcess().Id,
                        error_type = exception.GetType().Name,
                        error_message = exception.Message.Length > 300 ? exception.Message.Substring(0, 300) : exception.Message,
                        checked_at = DateTime.UtcNow.ToString("o")
                    };
                    File.WriteAllText(options.HotkeyStatusPath, new JavaScriptSerializer().Serialize(diagnostic), new UTF8Encoding(false));
                } catch (IOException) { }
                catch (UnauthorizedAccessException) { }
            }
            if (Array.IndexOf(args, "--quiet-control-error") < 0)
                MessageBox.Show(exception.Message, "Qicheng Windows Channels", MessageBoxButtons.OK, MessageBoxIcon.Error);
            Environment.ExitCode = 1;
        }
    }
}
