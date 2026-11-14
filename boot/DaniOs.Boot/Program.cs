using DaniOs.Kernel.Host;

static string ResolveDaniRoot()
{
    var current = new DirectoryInfo(AppContext.BaseDirectory);
    while (current is not null)
    {
        if (File.Exists(Path.Combine(current.FullName, "boot", "init.ps1")))
            return current.FullName;

        current = current.Parent;
    }

    throw new DirectoryNotFoundException(
        $"Could not locate the Dani-OS root from '{AppContext.BaseDirectory}'.");
}

var engine = new KernelHostEngine(ResolveDaniRoot());
return engine.Boot(args);
