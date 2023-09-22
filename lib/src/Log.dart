import "dart:io";

bool g_LoggerVerbose = false;

void Log(String msg)
{
  print("[INFO] $msg");
}

void Err(String msg)
{
  int lastNewlineIndex = msg.lastIndexOf('\n');
  if (lastNewlineIndex == msg.length-1)
    stdout.write("\x1B[31m[ERROR] $msg\x1B[0m");
  else
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
    Log(msg);
}

void VerErr(String msg)
{
  if (g_LoggerVerbose)
    Err(msg);
}