bool g_LoggerVerbose = true;

void Log(String msg)
{
  print("[INFO] $msg");
}

void Err(String msg)
{
  print("\x1B[31m[ERROR] $msg\x1B[0m");
}

void Hint(String msg)
{
  print("\x1B[33m[HINT] $msg\x1B[0m");
}

void Suc(String msg)
{
  print("\x1B[32m[INFO] $msg\x1B[0m");
}

void Ver(String msg)
{
  if (g_LoggerVerbose)
    print("[INFO] $msg");
}