library ProgressBar;
import "dart:io";

class ProgressBar
{
  static const int _TotalSize = 31;
  static const int _RealSize = _TotalSize + 3;

  static final List<String> _Bar = List<String>.filled(_RealSize, '');
  static int _CurrentSize = 0;
  static int _LastPrintedPercent = 0;

  static void _Add(int blocks)
  {
    blocks = blocks - _CurrentSize;
    for (int i = 1; i < _TotalSize + 1; ++i)
    {
      if (_Bar[i] == '-')
      {
        if (i + blocks > (_TotalSize + 1))
        {
          blocks = _TotalSize - _CurrentSize;
        }
        _Bar.fillRange(i, i + blocks, '#');
        _CurrentSize += blocks;
        return;
      }
    }
  }

  static void Init()
  {
    _CurrentSize = 0;
    _Bar[0] = '[';
    _Bar[_RealSize - 2] = ']';
    for (int i = 1; i < _RealSize - 2; ++i)
    {
      _Bar[i] = '-';
    }
  }

  static void Show(int current, int total)
  {
    double percentDone = (current.toDouble() / total.toDouble()) * 100.0;
    int newBlocksToAdd = (percentDone * _TotalSize / 100).toInt();
    _Add(newBlocksToAdd);

    int currentPrintedPercent = (percentDone / 5).floor() * 5;
    if (currentPrintedPercent > _LastPrintedPercent)
    {
      String progressBar = _Bar.join();
      stdout.write('$progressBar ${percentDone.toStringAsFixed(2)}% ($current|$total)\r');
      _LastPrintedPercent = currentPrintedPercent;
      //if (percentDone == 100.0) print('');
    }
  }
}