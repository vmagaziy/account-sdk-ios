//
// Copyright 2011 - 2020 Schibsted Products & Technology AS.
// Licensed under the terms of the MIT license. See LICENSE in the project root.
//

class ErrorLabel: NormalLabel {
    override func applyTheme(theme: IdentityUITheme) {
        super.applyTheme(theme: theme)
        textColor = theme.colors.errorText
        font = theme.fonts.error
        numberOfLines = 0
    }
}
