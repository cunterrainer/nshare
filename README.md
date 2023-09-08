# Analyzer
This is an application that can displays plots with information sent from a device. The application parses formatted strings received from the device and displays the data as plots, with the x-axis being the elapsed time since the connection started.

The string should be in the format of `plot_name:y_label:graph_name:value\n`. However, all of these values except for `value` can be defaulted, thus there's no need to provide them if you don't want to.

# Application
![image info](./docs/image1.PNG)
You can customize the plots or legends by right clicking on them.

## Settings
### Cleanup Graphs
If this is enabled the app will try to clean the internally used arrays to only leave necessary entries to save memory and get a better performance. However eventhough the graphs should not be altered in this process it might happen, so consider disabling this feature if the graphs look odd.
### Cleanup only same
Only removed entries if their `y` values are the same (e.g. `f(x)=7`) can be reduced to two entries marking the first and last coordinate. This settings only works if `Cleanup Graphs` is also enabled.
### Debug info
Shows the number of coordinates every graphs has internally right next to it's name in the legend. It's called `Debug info` because activating it will cause the graphs to rapidly change their color however I wanted to leave it in because it might be a useful information for some people. 

# Example Usage
Here is an example of how to use this application:
1. Connect your Arduino board to your computer.
2. Open an IDE or text editor (e.g. Arduino IDE)
3. Upload the following code to your board:
```c++
void setup() 
{
  Serial.begin(9600);
}

static uint32_t i = 0;
void loop() 
{
  Serial.printf("##exp:y:2^n:%.12f\n", pow(2, i)/1000000000000.0);
  Serial.printf("##nlog:y:nlog(n):%.12f\n", i*log(i));
  Serial.printf("##log:y:log(n):%.12f\n", log(i)/100000.0);
  Serial.printf("##log:y:-log(n):%.12f\n", -log(i)/100000.0);
  ++i;
  delay(1000);
}
```
4. Run the Analyzer on your computer.
5. Choose the correct serial port and baud rate in the application settings.
6. Click on `Connect` and wait for the plots to appear, this might take some time.

# String Format
The following format is expected for the input string:

```
plot_name:y_label:graph_name:value\n
```

- `plot_name`: Will be centered above the plot. You can use "##" in front of the name to not show it as a title (e.g. `##log`). Defaults to `##default`.
- `y_label`: What's shown on the y-axis. Defaults to `y`.
- `graph_name`: The name of the graph, used to properly assign the values and is shown in the legend. Defaults to `f(x)`.
- `value`: The y-axis value. The x-axis will always show the elapsed time in seconds. This value cannot be defaulted.
- `\n`: The newline is important because it marks the end of an entry. Thus, every entry has to have one.

# Saving Plots
You can save the plots as images by clicking the "Save Plot" button in the application window. You can choose to save all plots in one image or save each plot separately in its own image. When saving, you can also choose to upscale or downscale the images.
![image info](./docs/image2.PNG)

# Supported devices
I've only been able to test it with an esp32 and an Arduino Uno, however other devices should work fine aswell, since all the application does is to parse the provided string, thus as long as the string is properly formatted it shouldn't be an issue to use something else.

# Platforms
- [x] Windows
- [X] Linux
- [X] macOS

If you are on linux the default build configuration is not posix compliant however if you need your build to be compliant see the 'Build' section for assistence on how to build it.

# Troubleshooting
## Device isn't listed
First check if the operating system can find it, if not make sure you have the proper drivers installed. To see where you can find your device port see below.
### Windows
Start->Device Manager->Ports (e.g., COM1, COM3)
### Linux
```
ls /dev/tty*
```
The board should either be `/dev/ttyACM0` or `/dev/ttyUSB0` if you have multiple entries you have to try it out manually.  
If you have the drivers installed and the board connected to you pc but it still doesn't show up try to restart the pc or try:
```
udevadm trigger
```
and check again
## Plots don't show up
This can have various reasons, one might be that the program doesn't receive properly formatted inputs, unfortunately that's something you have to check yourself because the application doesn't have a way to inform the user about wrongly formatted strings. If you still have problems even though your strings are properly formatted check that your not using a `\n` in `Serial.print()`. It is **not** advices to use this function for a newline, because for some reason, sometimes when using this the output gets corrupted. You can check if that's the case yourself by using the Arduino IDE's Serial Monitor. Simply open and close it a couple of times and you might see weird output (Make sure the proper baud rate is set). It is advised to use either `Serial.printf()` or `Serial.println()` for sending the `\n`. You can still use `Serial.print()` just don't use it for the newline.

# Build
## Prerequisites
### Windows
Nothing, everything is provided.
### Linux
Following libraries have to be installed and accessible to the current user:
- xorg (should contain:)
  - libx11
  - libxcursor
  - libxrandr
  - libxinerama
  - libxi
- gtk-3
- glib-2
- libgobject-2.0 (only some distros)

To build the Wayland version instead if X11 you need to have `wayland`, `wayland-scanner`, `wayland-protocols` and `wayland-client` installed.  
On some distros you have to make sure to install the developement `-dev` versions.
### macOS
You need to install `premake5` manually, the suggested way is to use homebrew
```
brew install premake
```

## Using premake
This is the prefered and only way if you want to have a visual studio project. The project uses premake as it's build system with the premake5 binaries already provided. I've tested building it with visual studio, clang and gcc, however other compilers might work aswell, just give it a try.

For additional information use:

Windows
```
vendor\premake5.exe --help
```

Linux
```
vendor/premake5 --help
```

macOS
```
premake5 --help
```

## Clone

```
git clone https://github.com/pyvyx/Hardware-Plotter.git
```
```
cd Hardware-Plotter
```

## Visual Studio

```
vendor\premake5.exe vs2022
```
This should generate a .sln file

## Make

Windows
```
vendor\premake5.exe gmake [cc]
```

Linux
```
vendor/premake5 gmake [cc] [options]
```

macOS
```
premake5 gmake [cc]
```

GCC should be the default compiler on Windows and Linux, macOS uses clang as default, however you can explicitly specify it if you'd like.  
GCC:   --cc=gcc  
Clang: --cc=clang  
There are also other compilers available however building has only been tested with gcc, clang and msvc

### Options
`--posix` For a posix compliant build  
`--wayland` To use Wayland instead of X11

### Build

```
make [-j] config=<configuration>
```
Configurations:
 - debug_x86
 - debug_x64 (default, the same as just using `make`)
 - release_x86
 - release_x64

MacOS:
 - debug_universal (default, the same as just using `make`)
 - release_universal

`-j` flag utilises multithreaded compilation

```
make help
```
for additional information

## Using build script
If your just interested in building the project (without project files) you can use the provided script in `scripts\`. This script has to be executed from the main directory.
```
python scripts/build.py [cc]
```
Replace `[cc]` with either `gcc` or `clang` or leave it empty to build both
