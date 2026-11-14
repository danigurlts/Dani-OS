using DaniOs.Kernel.Host;
string bootDir = AppContext.BaseDirectory;
string daniRoot = Directory.GetParent(bootDir.TrimEnd(Path.DirectorySeparatorChar))?.FullName ?? bootDir;
var engine = new KernelHostEngine(daniRoot);
return engine.Boot(args);
