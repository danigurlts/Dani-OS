using DaniOs.Kernel.Host;

static string FindDaniRoot()
{
    var current = new DirectoryInfo(AppContext.BaseDirectory);
    while (current is not null)
    {
        if (File.Exists(Path.Combine(current.FullName, "boot", "init.ps1")))
            return current.FullName;

        current = current.Parent;
    }

    throw new DirectoryNotFoundException(
        $"Could not locate boot/init.ps1 from application directory '{AppContext.BaseDirectory}'.");
}

var engine = new KernelHostEngine(FindDaniRoot());
return engine.Boot(args);
