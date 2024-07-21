import 'package:flutter/material.dart';
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
  bool autodetectLocalIp = false;
  bool isSender = true;
  ReceiverServer _Receiver = ReceiverServer();
  SenderSocket _Sender = SenderSocket();
  Widget _ConnectButtonChild = Text("Connect");

  final List<String> items = [
    "Item 1",
    "Item 2",
    "Item 3",
    "Item 4",
    "Item 5",
    // Add more items as needed
  ];

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
                          Text('IP:'),
                          SizedBox(width: 8),
                          Expanded(
                            child: TextField(
                              controller: ipController,
                              decoration: InputDecoration(
                                border: OutlineInputBorder(),
                                hintText: 'Enter IP address',
                              ),
                          )),
                        ],
                      ),
                      SizedBox(height: 16),
                      Row(
                        children: [
                          Text('Port:'),
                          SizedBox(width: 8),
                          Expanded(
                              child: TextField(
                                controller: portController,
                                decoration: InputDecoration(
                                  border: OutlineInputBorder(),
                                  hintText: 'Enter Port number',
                                ),
                              )),
                        ],
                      ),
                      SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: <Widget>[
                          Row(
                            children: <Widget>[Checkbox(
                              value: autodetectLocalIp,
                              onChanged: (bool? value) {
                                setState(() {
                                  autodetectLocalIp = value!;
                                });
                              },
                            ),
                            Text('Autodetect'),
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
                      SizedBox(height: 16),
                      Text("Local ip: "),
                    ],
                  ),
                ),
                Expanded(
                  child: Column(
                    children: [
                      ElevatedButton(
                        onPressed: () async {
                          setState(() {
                            _ConnectButtonChild = CircularProgressIndicator();
                          });
                          String? error = isSender ? await _Sender.Connect(ipController.text, portController.text) : await _Receiver.Connect(portController.text);

                          if (error != null)
                          {
                            showDialog(
                              context: context,
                              builder: (BuildContext context) {
                                return AlertDialog(
                                  title: Text("Error"),
                                  content: Text(error),
                                  actions: [
                                    TextButton(
                                      child: Text("Ok"),
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
                            _ConnectButtonChild = _Sender.IsConnected() || _Receiver.IsConnected() ? Text("Disconnect") : Text("Connect");
                          });
                        },
                        style: ElevatedButton.styleFrom(
                            shape: CircleBorder(),
                            padding: EdgeInsets.all(70)
                        ),
                        child: _ConnectButtonChild,
                      ),
                      Visibility(
                        visible: true,
                        child: SizedBox(height: 40),
                      ),
                      Visibility(
                        visible: true,
                        child: ElevatedButton(
                            onPressed: () {
                              // Add functionality here
                            },
                            child: Text('Start')
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
                            child: TextField(
                            controller: ipController,
                            decoration: InputDecoration(
                              border: OutlineInputBorder(),
                              hintText: "File path",
                            ),
                            )
                          ),
                          SizedBox(width: 8),
                          ElevatedButton(
                            onPressed: null,
                            child: Text("Add files"),
                          ),
                        ],
                      ),
                      SizedBox(height: 16),
                      Visibility(
                        visible: isSender,
                        child: SingleChildScrollView(
                          child: Container(
                            height: 200, // Set the desired height
                            child: ListView.builder(
                              shrinkWrap: true, // Use shrinkWrap to make the list view take only the necessary height
                              itemCount: items.length,
                              itemBuilder: (context, index) {
                                return ListTile(
                                  title: Text(items[index]),
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
            SizedBox(height: 50),
            Text("File"),
            LinearProgressIndicator(
              value: 0.5,
            ),
            SizedBox(height: 50),
            Text("Total"),
            LinearProgressIndicator(
              value: 0.4,
            )
          ],
        ),
      ),
    );
  }
}
