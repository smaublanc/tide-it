//
//  TideWatchWidgetBundle.swift
//  TideWatchWidget
//
//  Complications watchOS pour le cadran Apple Watch
//

import WidgetKit
import SwiftUI

@main
struct TideWatchWidgetBundle: WidgetBundle {
    var body: some Widget {
        TideWatchComplication()       // marée (corner/circular/rectangular/inline)
        TideWatchWindComplication()   // vent observé (small : circular/corner)
    }
}
