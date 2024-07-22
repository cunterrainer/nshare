import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:nshare/Server.dart';

void main() => runApp(MyApp());

class MyApp extends StatelessWidget
{
  @override
  Widget build(BuildContext context)
  {
    return MaterialApp(
      home: HomePage(),
    );
  }
}

class HomePage extends StatefulWidget
{
  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage>
{
  TextEditingController ipController = TextEditingController();
  TextEditingController portController = TextEditingController();
  bool _AutoDetect = false;
  bool isSender = true;
  final ReceiverServer _Receiver = ReceiverServer();
  final SenderSocket _Sender = SenderSocket();
  Widget _ConnectButtonChild = const Text("Connect");
  final List<String> _Paths = [];

  @override
  Widget build(BuildContext context)
  {
    return Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      Row(
                        children: [
                          const Text('IP:'),
                          const SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              enabled: isSender && !_AutoDetect,
                              controller: ipController,
                              decoration: const InputDecoration(
                                border: OutlineInputBorder(),
                                hintText: 'Enter IP address',
                              ),
                          )),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          const Text('Port:'),
                          const SizedBox(width: 8),
                          Expanded(
                              child: TextField(
                                enabled: !_AutoDetect,
                                controller: portController,
                                decoration: const InputDecoration(
                                  border: OutlineInputBorder(),
                                  hintText: 'Enter Port number',
                                ),
                              )),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: <Widget>[
                          Row(
                            children: <Widget>[
                              Checkbox(
                                value: _AutoDetect,
                                onChanged: (bool? value) {
                                  setState(() {
                                    _AutoDetect = value!;
                                  });
                                },
                              ),
                              const Text('Autodetect'),
                            ]
                          ),
                          ElevatedButton(
                            onPressed: () {
                              setState(() {
                                isSender = !isSender;
                              });
                            },
                            child: Text(isSender ? "Sender" : "Receiver"),
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      const Text("Local ip: "),
                    ],
                  ),
                ),
                Expanded(
                  child: Column(
                    children: [
                      ElevatedButton(
                        onPressed: () async {
                          setState(() {
                            _ConnectButtonChild = const CircularProgressIndicator();
                          });
                          String? error = isSender ? await _Sender.Connect(ipController.text, portController.text) : await _Receiver.Connect(portController.text);

                          if (error != null)
                          {
                            showDialog(
                              context: context,
                              builder: (BuildContext context) {
                                return AlertDialog(
                                  title: const Text("Error"),
                                  content: Text(error),
                                  actions: [
                                    TextButton(
                                      child: const Text("Ok"),
                                      onPressed: () {
                                        Navigator.of(context).pop();
                                      },
                                    )
                                  ],
                                );
                              }
                            );
                          }
                          setState(() {
                            _ConnectButtonChild = _Sender.IsConnected() || _Receiver.IsConnected() ? const Text("Disconnect") : const Text("Connect");
                          });
                        },
                        style: ElevatedButton.styleFrom(
                            shape: const CircleBorder(),
                            padding: const EdgeInsets.all(70)
                        ),
                        child: _ConnectButtonChild,
                      ),
                      const Visibility(
                        visible: true,
                        child: SizedBox(height: 40),
                      ),
                      Visibility(
                        visible: true,
                        child: ElevatedButton(
                            onPressed: () {
                              // Add functionality here
                            },
                            child: const Text('Start')
                        ),
                      ),
                    ],
                  )
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: <Widget>[
                      Row(
                        children: [
                          Expanded(
                            child: ElevatedButton(
                            onPressed: () async {
                              String? selectedDirectory = await FilePicker.platform.getDirectoryPath();

                              setState(() {
                                if (selectedDirectory != null)
                                {
                                  _Paths.add(selectedDirectory);
                                }
                              });
                            },
                            child: const Text("Add folder"),
                            )
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: ElevatedButton(
                            onPressed: () async {
                              FilePickerResult? result = await FilePicker.platform.pickFiles(allowMultiple: true);
                              setState(() {
                                if (result != null)
                                {
                                  for (String? s in result.paths)
                                  {
                                    if (s != null)
                                    {
                                      _Paths.add(s);
                                    }
                                  }
                                }
                              });
                            },
                            child: const Text("Add files"),
                            ),
                          )
                        ],
                      ),
                      const SizedBox(height: 16),
                      Visibility(
                        visible: isSender && _Paths.isNotEmpty,
                        child: SingleChildScrollView(
                          child: SizedBox(
                            height: 200, // Set the desired height
                            child: ListView.builder(
                              shrinkWrap: true, // Use shrinkWrap to make the list view take only the necessary height
                              itemCount: _Paths.length,
                              itemBuilder: (context, index) {
                                return ListTile(
                                  title: Text(_Paths[index]),
                                  trailing: IconButton(
                                    icon: const Icon(Icons.delete),
                                    onPressed: () {
                                      setState(() {
                                        _Paths.removeAt(index);
                                      });
                                    },
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      )
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 50),
            const Text("File"),
            const LinearProgressIndicator(
              value: 0.5,
            ),
            const SizedBox(height: 50),
            const Text("Total"),
            const LinearProgressIndicator(
              value: 0.4,
            )
          ],
        ),
      ),
    );
  }
}
