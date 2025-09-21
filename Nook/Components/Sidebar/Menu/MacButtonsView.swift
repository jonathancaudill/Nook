//
//  MacButtonsView.swift
//  Nook
//
//  Created by Maciek Bagiński on 17/09/2025.
//

import SwiftUI

struct MacButtonsView: View {
    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(Color.red)
                .frame(width: 12, height: 12)
            Circle()
                .fill(Color.yellow)
                .frame(width: 12, height: 12)
            Circle()
                .fill(Color.green)
                .frame(width: 12, height: 12)
        }
    }
}
