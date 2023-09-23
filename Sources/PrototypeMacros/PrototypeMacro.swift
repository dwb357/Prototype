import SwiftCompilerPlugin
import SwiftSyntax
import SwiftSyntaxBuilder
import SwiftSyntaxMacros
import SwiftSyntaxExtensions

/// The peer macro implementation of the `@Prototype` macro.
public struct PrototypeMacro: PeerMacro {
    public static func expansion(
        of node: AttributeSyntax,
        providingPeersOf declaration: some DeclSyntaxProtocol,
        in context: some MacroExpansionContext
    ) throws -> [DeclSyntax] {
        guard isSupportedPeerDeclaration(declaration) else {
            throw PrototypeMacrosError.macro("Prototype", canOnlyBeAttachedTo: .classOrStructDeclaration)
        }
        
        let arguments = try PrototypeArguments(from: node)
        let spec = try PrototypeSpec(parsing: declaration)
        var result: [DeclSyntax] = []

        try arguments.kinds.forEach { kind in
            switch kind {
            case .form:
                let members = spec.members.filter { member in member.attributes.contains(.visible) }
                var isInSection = false
                var body: [String] = []
                
                try members.forEach { member in
                    if member.attributes.contains(.section) {
                        if isInSection {
                            body.append("}")
                        }
                        
                        isInSection = true
                        
                        if let sectionTitle = member.sectionTitle {
                            body.append("Section(header: Text(\"\(spec.name)Form.\(sectionTitle)\")) {")
                        } else {
                            body.append("Section {")
                        }
                    }
                    
                    body.append(try buildMemberSpecFormSyntax(arguments: arguments, keyPrefix: "\(spec.name)Form", spec: member))
                }
                
                if isInSection {
                    body.append("}")
                }
                
                result.append(
                """
                \(raw: spec.accessLevelModifiers.structDeclAccessLevelModifiers) struct \(raw: spec.name)Form: View {
                @Binding public var model: \(raw: spec.name)
                private let footer: AnyView?
                private let numberFormatter: NumberFormatter
                
                public init(model: Binding<\(raw: spec.name)>, numberFormatter: NumberFormatter = .init()) {
                    self._model = model
                    self.footer = nil
                    self.numberFormatter = numberFormatter
                }
                
                public init<Footer>(model: Binding<\(raw: spec.name)>, numberFormatter: NumberFormatter = .init(), @ViewBuilder footer: () -> Footer) where Footer: View {
                    self._model = model
                    self.footer = AnyView(erasing: footer())
                    self.numberFormatter = numberFormatter
                }

                public var body: some View {
                    Form {
                        \(raw: body.joined(separator: "\n"))
                
                        if let footer {
                            footer
                        }
                    }
                }
                }
                """
                )
                
            case .settings:
                let members = spec.members.filter { member in member.attributes.contains(.visible) }
                var isInSection = false
                var properties: [String] = []
                var body: [String] = []
                
                members.forEach { member in
                    let key = "\(spec.name).\(member.name)"
                    let initializer = member.initializer?.description ?? "= .init()"
                    
                    properties.append("@AppStorage(\"\(key)\") private var \(member.name): \(member.type) \(initializer)")
                }
                
                try members.forEach { member in
                    if member.attributes.contains(.section) {
                        if isInSection {
                            body.append("}")
                        }
                        
                        isInSection = true
                        
                        if let sectionTitle = member.sectionTitle {
                            body.append("Section(header: Text(\"\(spec.name)Form.\(sectionTitle)\")) {")
                        } else {
                            body.append("Section {")
                        }
                    }
                    
                    body.append(try buildMemberSpecSettingsSyntax(arguments: arguments, keyPrefix: "\(spec.name)SettingsView", spec: member))
                }
                
                if isInSection {
                    body.append("}")
                }
                
                result.append(
                """
                \(raw: spec.accessLevelModifiers.structDeclAccessLevelModifiers) struct \(raw: spec.name)SettingsView: View {
                \(raw: properties.joined(separator: "\n"))
                private let footer: AnyView?
                private let numberFormatter: NumberFormatter
                
                public init<Footer>(numberFormatter: NumberFormatter = .init(), @ViewBuilder footer: () -> Footer) where Footer: View {
                    self.footer = AnyView(erasing: footer())
                    self.numberFormatter = numberFormatter
                }

                public var body: some View {
                    Form {
                        \(raw: body.joined(separator: "\n"))
                
                        if let footer {
                            footer
                        }
                    }
                }
                }
                """
                )
                
            case .view:
                let members = spec.members.filter { member in member.attributes.contains(.visible) }
                var isInSection = false
                var body: [String] = []
                
                try members.forEach { member in
                    if member.attributes.contains(.section) {
                        if isInSection {
                            body.append("}")
                        }
                        
                        isInSection = true
                        
                        if let sectionTitle = member.sectionTitle {
                            body.append("GroupBox(\"\(spec.name)View.\(sectionTitle)\") {")
                        } else {
                            body.append("GroupBox {")
                        }
                    }
                    
                    body.append(try buildMemberSpecViewSyntax(arguments: arguments, keyPrefix: "\(spec.name)View", spec: member))
                }
                
                if isInSection {
                    body.append("}")
                }
                
                if body.isEmpty {
                    body.append("EmptyView()")
                }
                
                result.append(
                """
                \(raw: spec.accessLevelModifiers.structDeclAccessLevelModifiers) struct \(raw: spec.name)View: View {
                public let model: \(raw: spec.name)
                
                public init(model: \(raw: spec.name)) {
                    self.model = model
                }

                public var body: some View {
                    \(raw: body.joined(separator: "\n"))
                }
                }
                """
                )
            }
        }
        
        return result
    }
}

extension PrototypeMacro {
    private static func isSupportedPeerDeclaration(_ declaration: DeclSyntaxProtocol) -> Bool {
        return (
            declaration.is(ClassDeclSyntax.self) ||
            declaration.is(StructDeclSyntax.self)
        )
    }
}

extension PrototypeMacro {
    private static let numericTypes = [
        "Int8", "Int16", "Int32", "Int64", "Int",
        "UInt8", "UInt16", "UInt32", "UInt64", "UInt",
        "Float16", "Float32", "Float64", "Float80", "Float", "Double"
    ]

    private static func buildMemberSpecFormSyntax(
        arguments: PrototypeArguments,
        keyPrefix: String,
        spec: PrototypeMemberSpec
    ) throws -> String {
        guard spec.attributes.contains(.visible) else { return "" }

        var result: [String] = []
        let key = "\"\(keyPrefix).\(spec.name)\""
        let labelKey = "\"\(keyPrefix).\(spec.name).label\""
        let binding = spec.attributes.contains(.modifiable) ? "$model.\(spec.name)" : ".constant(model.\(spec.name))"

        if arguments.style == .labeled {
            result.append("LabeledContent(\(labelKey)) {")
        }
        
        switch spec.type {
        case "Bool":
            result.append("Toggle(\(key), isOn: \(binding))")

        case "String":
            if spec.attributes.contains(.secure) {
                result.append("SecureField(\(key), text: \(binding))")
            } else {
                result.append("TextField(\(key), text: \(binding))")
            }
            
        case "Date":
            result.append("DatePicker(\(key), selection: \(binding))")

        default:
            if numericTypes.contains(spec.type) {
                result.append("TextField(\(key), value: \(binding), formatter: numberFormatter)")
            } else {
                result.append("\(spec.type)Form(model: \(binding))")
            }
        }
        
        if arguments.style == .labeled {
            result.append("}")
        }
        
        return result.joined(separator: "\n")
    }
    
    private static func buildMemberSpecSettingsSyntax(
        arguments: PrototypeArguments,
        keyPrefix: String,
        spec: PrototypeMemberSpec
    ) throws -> String {
        guard spec.attributes.contains(.visible) else { return "" }

        var result: [String] = []

        let key = "\"\(keyPrefix).\(spec.name)\""
        let labelKey = "\"\(keyPrefix).\(spec.name).label\""
        let binding = spec.attributes.contains(.modifiable) ? "$\(spec.name)" : ".constant(\(spec.name))"

        if arguments.style == .labeled {
            result.append("LabeledContent(\(labelKey)) {")
        }
        
        switch spec.type {
        case "Bool":
            result.append("Toggle(\(key), isOn: \(binding))")

        case "String":
            if spec.attributes.contains(.secure) {
                result.append("SecureField(\(key), text: \(binding))")
            } else {
                result.append("TextField(\(key), text: \(binding))")
            }
            
        case "Date":
            result.append("DatePicker(\(key), selection: \(binding))")

        default:
            if numericTypes.contains(spec.type) {
                result.append("TextField(\(key), value: \(binding), formatter: numberFormatter)")
            } else {
                result.append("\(spec.type)Form(model: \(binding))")
            }
        }
        
        if arguments.style == .labeled {
            result.append("}")
        }
        
        return result.joined(separator: "\n")
    }
    
    private static func buildMemberSpecViewSyntax(
        arguments: PrototypeArguments,
        keyPrefix: String,
        spec: PrototypeMemberSpec
    ) throws -> String {
        guard spec.attributes.contains(.visible) else { return "" }

        var result: [String] = []

        let key = "\"\(keyPrefix).\(spec.name)\""
        let labelKey = "\"\(keyPrefix).\(spec.name).label\""

        if arguments.style == .labeled {
            result.append("LabeledContent(\(labelKey)) {")
        }
        
        let numericTypes = [
            "Int8", "Int16", "Int32", "Int64", "Int", 
            "UInt8", "UInt16", "UInt32", "UInt64", "UInt",
            "Float16", "Float32", "Float64", "Float80", "Float", "Double"
        ]
        
        if spec.type == "Bool" {
            result.append(
            """
            LabeledContent(\(key)) {
                Text(model.\(spec.name).description)
            }
            """
            )
        } else if spec.type == "String" {
            if spec.attributes.contains(.secure) {
                result.append("LabeledContent(\(key), value: \"********\")")
            } else {
                result.append("LabeledContent(\(key), value: model.\(spec.name))")
            }
        } else if spec.type == "Date" {
            result.append("LabeledContent(\(key), value: model.\(spec.name), format: .dateTime)")
        } else if numericTypes.contains(spec.type) {
            result.append("LabeledContent(\(key), value: model.\(spec.name), format: .number)")
        } else {
            result.append("\(spec.type)View(model: model.\(spec.name))")
        }
        
        if arguments.style == .labeled {
            result.append("}")
        }
        
        return result.joined(separator: "\n")
    }
}
