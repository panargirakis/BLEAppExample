//
//  ViewController.swift
//  SimpleBleCentral
//
//  Created by Panagiotis Argyrakis on 6/17/18.
//  Copyright © 2018 Panagiotis Argyrakis. All rights reserved.
//

import UIKit
import BlueCapKit
import CoreBluetooth

class ViewController: UIViewController {
    
    class worldState {
        var r: UInt8
        var g: UInt8
        var b: UInt8
        var isOn: Bool
        var brightness: UInt8
        var connected: Bool
        
        private var packetLength: Int
        
        init() {
            self.r = 0
            self.g = 0
            self.b = 0
            self.isOn = true
            self.brightness = 128
            self.connected = false
            self.packetLength = 4
        }
        
        private func packetData() -> [UInt8] {
            var temp: UInt8 = 0
            if isOn {
                temp = brightness
            }
            return [r, g, b, temp]
        }
        
        func getPacket() -> Data {
            return NSData(bytes: packetData() as [UInt8], length: packetLength) as Data
        }
    }
    
    public enum AppError : Error {
        case dataCharactertisticNotFound
        case enabledCharactertisticNotFound
        case updateCharactertisticNotFound
        case serviceNotFound
        case invalidState
        case resetting
        case poweredOff
        case unknown
    }
    
    //MARK: Properties
    @IBOutlet weak var redSlider: UISlider!
    @IBOutlet weak var greenSlider: UISlider!
    @IBOutlet weak var blueSlider: UISlider!
    @IBOutlet weak var brightnSlider: UISlider!
    @IBOutlet weak var onOffButton: UIButton!
    @IBOutlet weak var connStatusLabel: UILabel!
    
    var dataCharacteristic : Characteristic?
    
    var ws = worldState()
    
    override func viewDidLoad() {
        super.viewDidLoad()
        // set text for onOff button
        if ws.isOn {
            onOffButton.setTitle("ON", for: .normal)
            onOffButton.setTitleColor(.green, for: .normal)
        } else {
            onOffButton.setTitle("OFF", for: .normal)
            onOffButton.setTitleColor(.red, for: .normal)
        }
        // set the text for connection label
        if ws.connected {
            connStatusLabel.text = "Connected"
            connStatusLabel.textColor = UIColor.green
        } else {
            connStatusLabel.text = "Not Connected"
            connStatusLabel.textColor = UIColor.red
        }
        
//        // Setup Color Picker
//        colorPicker.setViewColor(.white)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        
        let serviceUUID = CBUUID(string:"80865467-9c99-4cce-a94e-48058d175fed")
        var peripheral: Peripheral?
        let dateCharacteristicUUID = CBUUID(string:"011c9658-f282-4ddc-97a9-a1b1fb6c52b9")
        
        //initialize a central manager with a restore key. The restore key allows to resuse the same central manager in future calls
        let manager = CentralManager(options: [CBCentralManagerOptionRestoreIdentifierKey : "CentralMangerKey" as NSString])
        
        //A future stram that notifies us when the state of the central manager changes
        let stateChangeFuture = manager.whenStateChanges()
        
        //handle state changes and return a scan future if the bluetooth is powered on.
        let scanFuture = stateChangeFuture.flatMap { state -> FutureStream<Peripheral> in
            switch state {
            case .poweredOn:
                DispatchQueue.main.async {
                    self.connStatusLabel.text = "start scanning"
                    print(self.connStatusLabel.text!)
                }
                //scan for peripherlas that advertise the ec00 service
                return manager.startScanning(forServiceUUIDs: [serviceUUID])
            case .poweredOff:
                throw AppError.poweredOff
            case .unauthorized, .unsupported:
                throw AppError.invalidState
            case .resetting:
                throw AppError.resetting
            case .unknown:
                //generally this state is ignored
                throw AppError.unknown
            }
        }
        scanFuture.onFailure { error in
            guard let appError = error as? AppError else {
                return
            }
            switch appError {
            case .invalidState:
                break
            case .resetting:
                manager.reset()
            case .poweredOff:
                break
            case .unknown:
                break
            default:
                break;
            }
        }
        
        //We will connect to the first scanned peripheral
        let connectionFuture = scanFuture.flatMap { p -> FutureStream<Void> in
            //stop the scan as soon as we find the first peripheral
            manager.stopScanning()
            peripheral = p
            guard let peripheral = peripheral else {
                throw AppError.unknown
            }
            DispatchQueue.main.async {
                self.connStatusLabel.text = "Found peripheral \(peripheral.identifier.uuidString). Trying to connect"
                print(self.connStatusLabel.text!)
            }
            //connect to the peripheral in order to trigger the connected mode
            return peripheral.connect(connectionTimeout: 10, capacity: 5)
        }
        
        //we will next discover the "ec00" service in order be able to access its characteristics
        let discoveryFuture = connectionFuture.flatMap { _ -> Future<Void> in
            guard let peripheral = peripheral else {
                throw AppError.unknown
            }
            return peripheral.discoverServices([serviceUUID])
            }.flatMap { _ -> Future<Void> in
                guard let discoveredPeripheral = peripheral else {
                    throw AppError.unknown
                }
                guard let service = discoveredPeripheral.services(withUUID:serviceUUID)?.first else {
                    throw AppError.serviceNotFound
                }
                peripheral = discoveredPeripheral
                DispatchQueue.main.async {
                    self.connStatusLabel.text = "Discovered service \(service.uuid.uuidString). Trying to discover characteristics"
                    print(self.connStatusLabel.text!)
                }
                //we have discovered the service, the next step is to discover the "ec0e" characteristic
                return service.discoverCharacteristics([dateCharacteristicUUID])
        }
        /**
         1- checks if the characteristic is correctly discovered
         2- Register for notifications using the dataFuture variable
         */
        let dataFuture = discoveryFuture.flatMap { _ -> Future<Void> in
            guard let discoveredPeripheral = peripheral else {
                throw AppError.unknown
            }
            guard let dataCh = discoveredPeripheral.services(withUUID:serviceUUID)?.first?.characteristics(withUUID:dateCharacteristicUUID)?.first else {
                throw AppError.dataCharactertisticNotFound
            }
            self.dataCharacteristic = dataCh
            DispatchQueue.main.async {
                self.connStatusLabel.text = "Discovered characteristic \(dataCh.uuid.uuidString). COOL :)"
                self.connStatusLabel.textColor = .green
                print(self.connStatusLabel.text!)
            }
            return dataCh.write(data: self.ws.getPacket(), type: CBCharacteristicWriteType.withoutResponse)
        }
        
        dataFuture.onFailure { error in
            switch error {
            case PeripheralError.disconnected:
                peripheral?.reconnect()
            case AppError.serviceNotFound:
                break
            case AppError.dataCharactertisticNotFound:
                break
            default:
                break
            }
        }
    }
    
    func write(){
        //write a value to the characteristic
        let writeFuture = self.dataCharacteristic?.write(data: ws.getPacket(),
                                                         type: CBCharacteristicWriteType.withoutResponse)
        writeFuture?.onSuccess(completion: { (_) in
            print("write succes")
        })
        writeFuture?.onFailure(completion: { (e) in
            print("write failed")
        })
    }
    
    //MARK: Actions
    @IBAction func setOnOff(_ sender: UIButton) {
        ws.isOn = !ws.isOn
        if ws.isOn {
            sender.setTitle("ON", for: .normal)
            sender.setTitleColor(.green, for: .normal)
        } else {
            sender.setTitle("OFF", for: .normal)
            sender.setTitleColor(.red, for: .normal)
        }
        write()
    }
    @IBAction func setBrightn(_ sender: UISlider) {
        ws.brightness = UInt8(sender.value)
        write()
    }
    @IBAction func setRed(_ sender: UISlider) {
        ws.r = UInt8(sender.value)
        write()
    }
    @IBAction func setG(_ sender: UISlider) {
        ws.g = UInt8(sender.value)
        write()
    }
    @IBAction func setB(_ sender: UISlider) {
        ws.b = UInt8(sender.value)
        write()
    }
}

