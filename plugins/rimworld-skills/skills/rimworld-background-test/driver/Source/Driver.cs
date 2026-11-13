using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text;
using RimWorld;
using Verse;
using Waylith;

namespace BackgroundTestDriver;

// Runs a plain-text step script (one command per line) on the main thread, one step at a time.
// Acts only with -tdscript=PATH and a -savedatafolder outside the default LocalLow folder, so a copy
// left in Mods does nothing in a normal game. Output goes to -tdout=DIR (default: the script's folder).
[StaticConstructorOnStartup]
public static class Driver
{
    private const BindingFlags Any = BindingFlags.Public | BindingFlags.NonPublic | BindingFlags.Static | BindingFlags.Instance | BindingFlags.FlattenHierarchy;

    private static readonly string OutDir;
    private static readonly List<string[]> Steps = new();
    private static StreamWriter _log;
    private static readonly Stopwatch Total = Stopwatch.StartNew();
    private static readonly Stopwatch StepSw = new();
    private static readonly Stopwatch FrameSw = new();
    private static readonly List<double> Frames = new();

    private static int _index;
    private static int _frames;
    private static int _counter;
    private static long _shotLen;
    private static bool _finished;

    static Driver()
    {
        if (!GenCommandLine.TryGetCommandLineArg("tdscript", out var script) || !File.Exists(script))
            return;
        string folder = GenFilePaths.SaveDataFolderPath ?? "";
        if (folder.IndexOf("LocalLow", StringComparison.OrdinalIgnoreCase) >= 0)
        {
            Verse.Log.Error("[BackgroundTestDriver] Refusing to run in the default save data folder: " + folder);
            return;
        }
        OutDir = GenCommandLine.TryGetCommandLineArg("tdout", out var o) && !string.IsNullOrWhiteSpace(o) ? o : Path.GetDirectoryName(script);
        Directory.CreateDirectory(OutDir);
        _log = new StreamWriter(Path.Combine(OutDir, "driver-log.txt"), false, new UTF8Encoding(false)) { AutoFlush = true };
        foreach (string raw in File.ReadAllLines(script))
        {
            string line = raw.Trim();
            if (line.Length == 0 || line.StartsWith("#"))
                continue;
            Steps.Add(line.Split((char[])null, StringSplitOptions.RemoveEmptyEntries));
        }
        Mute();
        Log($"start: {Steps.Count} steps, save folder {folder}");
        Log($"volume master {Prefs.VolumeMaster}, game {Prefs.VolumeGame}, music {Prefs.VolumeMusic}, ambient {Prefs.VolumeAmbient}, ui {Prefs.VolumeUI}");
        EngineApplication.Instance.OnUpdate += Update;
    }

    private static void Log(string text) => _log.WriteLine($"{Total.Elapsed.TotalSeconds,7:0.0}s {text}");

    // The runner already zeroes the volumes in this instance's Prefs.xml; this keeps it silent even if
    // something re-applies preferences. Prefs are not saved here.
    private static void Mute()
    {
        Prefs.VolumeMaster = 0f;
        Prefs.VolumeGame = 0f;
        Prefs.VolumeMusic = 0f;
        Prefs.VolumeAmbient = 0f;
        Prefs.VolumeUI = 0f;
    }

    private static bool Idle => !LongEventHandler.AnyEventNowOrWaiting;

    private static bool MapReady => Current.ProgramState == ProgramState.Playing && Current.Game != null && Find.CurrentMap != null && Idle;

    private static void Update()
    {
        if (_finished)
            return;
        _frames++;
        try
        {
            if (Prefs.VolumeMaster > 0f)
                Mute();
            if (Total.Elapsed.TotalMinutes > 30)
                throw new Exception("driver timeout (30 min)");
            if (_index >= Steps.Count)
            {
                Finish(true, "end of script");
                return;
            }
            string[] step = Steps[_index];
            if (_frames == 1)
            {
                StepSw.Restart();
                Log("> " + string.Join(" ", step));
            }
            if (Run(step))
            {
                _index++;
                _frames = 0;
                _counter = 0;
            }
        }
        catch (Exception e)
        {
            Log("FAILED at step " + (_index + 1) + ": " + e);
            Finish(false, e.Message);
        }
    }

    private static void Finish(bool ok, string why)
    {
        _finished = true;
        Log((ok ? "RESULT: OK" : "RESULT: FAILED") + " (" + why + ")");
        Root.Shutdown();
    }

    private static string Arg(string[] s, int i, string fallback = null) => i < s.Length ? s[i] : fallback ?? throw new Exception($"'{s[0]}' needs argument {i}");

    private static string Rest(string[] s, int from) => string.Join(" ", s.Skip(from));

    private static int Int(string[] s, int i, int fallback) => i < s.Length ? int.Parse(s[i], CultureInfo.InvariantCulture) : fallback;

    // Returns true when the step is complete; false to be called again next frame.
    private static bool Run(string[] s)
    {
        switch (s[0].ToLowerInvariant())
        {
            case "load":
                if (_frames == 1 || Current.ProgramState != ProgramState.Entry || !Idle || _frames < 30)
                    return false;
                GameDataSaveLoader.LoadGame(Arg(s, 1));
                Steps.Insert(_index + 1, new[] { "waitmap" });
                return true;
            case "waitmap":
                if (!MapReady || _frames < 10)
                    return false;
                Find.TickManager.CurTimeSpeed = TimeSpeed.Paused;
                Map map = Find.CurrentMap;
                Log($"map ready: tick {Find.TickManager.TicksGame}, colonists {map.mapPawns.FreeColonistsSpawnedCount}, pawns {map.mapPawns.AllPawnsSpawnedCount}");
                return true;
            case "closewindows":
                foreach (Window w in Find.WindowStack.Windows.ToList())
                {
                    if (w is MainTabWindow_Inspect || w is ImmediateWindow)
                        continue;
                    Log("  closing " + w.GetType().FullName);
                    w.Close(false);
                }
                return true;
            case "speed":
                Find.TickManager.CurTimeSpeed = (TimeSpeed)Int(s, 1, 0);
                return true;
            case "tick":
            {
                int n = Int(s, 1, 1000);
                Find.TickManager.CurTimeSpeed = TimeSpeed.Paused;
                var sw = Stopwatch.StartNew();
                while (_counter < n && sw.ElapsedMilliseconds < 400)
                {
                    Find.TickManager.DoSingleTick();
                    _counter++;
                }
                if (_counter >= n)
                {
                    Log($"  ticked {n} in {StepSw.Elapsed.TotalSeconds:0.0}s ({n / StepSw.Elapsed.TotalSeconds:0} TPS), now {Find.TickManager.TicksGame}");
                    return true;
                }
                return false;
            }
            case "wait":
                return _frames > Int(s, 1, 10);
            case "waitsec":
                return StepSw.Elapsed.TotalSeconds >= double.Parse(Arg(s, 1), CultureInfo.InvariantCulture);
            case "select":
            {
                Pawn pawn = FindPawn(s);
                Find.Selector.ClearSelection();
                Find.Selector.Select(pawn);
                CameraJumper.TryJump(pawn);
                Log($"  selected {pawn.LabelShort} (id {pawn.thingIDNumber})");
                return true;
            }
            case "opentab":
            {
                Type type = TypeOf(Arg(s, 1));
                InspectTabBase tab = InspectTabManager.GetSharedInstance(type);
                if (!tab.IsVisible)
                    throw new Exception(type.Name + " is not visible for the selection");
                InspectPaneUtility.OpenTab(type);
                return true;
            }
            case "measure":
            {
                int warmup = 10;
                if (_frames <= warmup)
                {
                    Frames.Clear();
                    FrameSw.Restart();
                    return false;
                }
                Frames.Add(FrameSw.Elapsed.TotalMilliseconds);
                FrameSw.Restart();
                if (Frames.Count < Int(s, 1, 300))
                    return false;
                var sorted = Frames.OrderBy(x => x).ToList();
                Log($"  frame time [{Rest(s, 2)}]: mean {Frames.Average():0.00} ms, p95 {sorted[(int)(sorted.Count * 0.95)]:0.00} ms, max {sorted[^1]:0.00} ms over {Frames.Count} frames");
                return true;
            }
            case "shot":
            {
                string path = Path.Combine(OutDir, Arg(s, 1));
                if (_frames == 1)
                {
                    if (EngineApplication.Instance?.Headless == true)
                        throw new Exception("headless instance has nothing to capture; run without -Headless");
                    if (File.Exists(path))
                        File.Delete(path);
                    _shotLen = -1;
                    UnityEngine.ScreenCapture.CaptureScreenshot(path);
                    return false;
                }
                if (!File.Exists(path))
                {
                    if (StepSw.Elapsed.TotalSeconds > 20)
                        throw new Exception("no screenshot after 20 s");
                    return false;
                }
                long len = new FileInfo(path).Length;
                bool stable = len > 0 && len == _shotLen;
                _shotLen = len;
                if (stable)
                    Log($"  saved {Arg(s, 1)} ({len} bytes, {UnityEngine.Screen.width}x{UnityEngine.Screen.height})");
                return stable;
            }
            case "settab":
            {
                object tab = InspectTabManager.GetSharedInstance(TypeOf(Arg(s, 1)));
                SetPath(tab.GetType(), tab, Arg(s, 2), Rest(s, 3));
                return true;
            }
            case "setstatic":
                SetPath(TypeOf(Arg(s, 1)), null, Arg(s, 2), Rest(s, 3));
                return true;
            case "call":
            {
                Type type = TypeOf(Arg(s, 1));
                MethodInfo method = type.GetMethod(Arg(s, 2), Any) ?? throw new Exception("no method " + Arg(s, 2));
                object result = method.Invoke(null, null);
                Log("  returned " + (result ?? "null"));
                return true;
            }
            case "log":
                Log("  " + Rest(s, 1));
                return true;
            case "quit":
                Finish(true, "quit");
                return false;
            default:
                throw new Exception("unknown command " + s[0]);
        }
    }

    // select [colonist] [index | name part]
    private static Pawn FindPawn(string[] s)
    {
        var colonists = Find.CurrentMap.mapPawns.FreeColonistsSpawned
            .Where(p => !p.Downed && !p.DevelopmentalStage.Baby()).OrderBy(p => p.thingIDNumber).ToList();
        int argAt = s.Length > 1 && s[1].Equals("colonist", StringComparison.OrdinalIgnoreCase) ? 2 : 1;
        string key = Rest(s, argAt);
        if (key.Length == 0)
            return colonists.FirstOrDefault() ?? throw new Exception("no colonist on the map");
        if (int.TryParse(key, out int index))
            return index < colonists.Count ? colonists[index] : throw new Exception($"only {colonists.Count} colonists");
        return colonists.FirstOrDefault(p => p.LabelShort.IndexOf(key, StringComparison.OrdinalIgnoreCase) >= 0
                || p.Name?.ToStringFull.IndexOf(key, StringComparison.OrdinalIgnoreCase) >= 0)
            ?? throw new Exception("no colonist named " + key);
    }

    private static Type TypeOf(string name) => GenTypes.GetTypeInAnyAssembly(name) ?? throw new Exception("type not found: " + name);

    // Walks Member.Member... from a type (static) or an instance and sets the last member.
    private static void SetPath(Type type, object target, string path, string text)
    {
        string[] parts = path.Split('.');
        for (int i = 0; i < parts.Length - 1; i++)
        {
            target = Get(type, target, parts[i]);
            type = target.GetType();
        }
        string last = parts[^1];
        Type valueType = MemberType(type, last);
        object value;
        if (text.StartsWith("+=", StringComparison.Ordinal))
            value = Convert.ToInt32(Get(type, target, last)) + int.Parse(text.Substring(2), CultureInfo.InvariantCulture);
        else if (valueType.IsEnum)
            value = int.TryParse(text, out int n) ? Enum.ToObject(valueType, n) : Enum.Parse(valueType, text, true);
        else
            value = Convert.ChangeType(text, valueType, CultureInfo.InvariantCulture);
        Set(type, target, last, value);
        Log($"  {path} = {value}");
    }

    private static object Get(Type type, object target, string name)
    {
        if (type.GetField(name, Any) is FieldInfo f)
            return f.GetValue(target);
        if (type.GetProperty(name, Any) is PropertyInfo p)
            return p.GetValue(target);
        throw new Exception($"{type.Name} has no member {name}");
    }

    private static Type MemberType(Type type, string name)
    {
        if (type.GetField(name, Any) is FieldInfo f)
            return f.FieldType;
        if (type.GetProperty(name, Any) is PropertyInfo p)
            return p.PropertyType;
        throw new Exception($"{type.Name} has no member {name}");
    }

    private static void Set(Type type, object target, string name, object value)
    {
        if (type.GetField(name, Any) is FieldInfo f)
            f.SetValue(target, value);
        else if (type.GetProperty(name, Any) is PropertyInfo p)
            p.SetValue(target, value);
        else
            throw new Exception($"{type.Name} has no member {name}");
    }
}
