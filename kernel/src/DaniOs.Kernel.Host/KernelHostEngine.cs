using System.Management.Automation;
using System.Management.Automation.Runspaces;
using System.Runtime.InteropServices;
using Microsoft.PowerShell;

namespace DaniOs.Kernel.Host;

public sealed class KernelHostEngine
{
    private readonly string _daniRoot;

    public KernelHostEngine(string daniRoot)
    {
        _daniRoot = Path.GetFullPath(daniRoot);
    }

    public int Boot(string[] cliArgs)
    {
        string initScript = Path.Combine(_daniRoot, "boot", "init.ps1");
        if (!File.Exists(initScript))
        {
            Console.Error.WriteLine($"[DaniOs::Host] FATAL: Missing kernel entry script '{initScript}'.");
            return 2;
        }

        var iss = InitialSessionState.CreateDefault();
        if (RuntimeInformation.IsOSPlatform(OSPlatform.Windows))
        {
            iss.ExecutionPolicy = ExecutionPolicy.Bypass;
        }

        Environment.SetEnvironmentVariable("DANIOS_KERNEL_ROOT", _daniRoot);

        using var runspace = RunspaceFactory.CreateRunspace(iss);
        runspace.Open();

        using var ps = PowerShell.Create();
        ps.Runspace = runspace;

        ps.Streams.Error.DataAdded += (_, e) =>
        {
            var record = ps.Streams.Error[e.Index];
            Console.ForegroundColor = ConsoleColor.Red;
            Console.Error.WriteLine($"[DaniOs::KernelError] {record}");
            Console.ResetColor();
        };

        ps.Streams.Warning.DataAdded += (_, e) =>
        {
            var record = ps.Streams.Warning[e.Index];
            Console.ForegroundColor = ConsoleColor.Yellow;
            Console.WriteLine($"[DaniOs::Warning] {record.Message}");
            Console.ResetColor();
        };

        ps.Streams.Information.DataAdded += (_, e) =>
        {
            var record = ps.Streams.Information[e.Index];
            Console.WriteLine(record.MessageData);
        };

        Console.CancelKeyPress += (_, cancelArgs) =>
        {
            cancelArgs.Cancel = true;
            if (ps.InvocationStateInfo.State == PSInvocationState.Running)
            {
                ps.BeginStop(_ => { }, null);
            }
        };

        ps.AddScript($"& '{initScript.Replace("'", "''")}' @args");
        foreach (string arg in cliArgs)
        {
            ps.AddArgument(arg);
        }

        try
        {
            var results = ps.Invoke();
            foreach (var item in results)
            {
                if (item is not null)
                    Console.WriteLine(item.ToString());
            }

            return ps.HadErrors ? 1 : 0;
        }
        catch (PipelineStoppedException)
        {
            return 0;
        }
        catch (Exception ex)
        {
            Console.ForegroundColor = ConsoleColor.Red;
            Console.Error.WriteLine($"[DaniOs::HostPanic] {ex.Message}");
            Console.ResetColor();
            return 1;
        }
    }
}
