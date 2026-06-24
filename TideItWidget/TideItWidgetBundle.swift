//
//  TideItWidgetBundle.swift
//  TideItWidget
//
//  Created by Maublanc on 13/02/2026.
//

import WidgetKit
import SwiftUI

@main
struct TideItWidgetBundle: WidgetBundle {
    var body: some Widget {
        #if os(iOS)
        TideItWidget()
        WindWidget()
        SurfWidget()
        TideItConfigurableWidget()
        TideLiveActivity()
        #endif
        TideLockScreenWidget()
    }
}
