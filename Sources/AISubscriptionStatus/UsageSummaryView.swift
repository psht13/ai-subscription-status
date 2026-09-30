import AppKit

/// Read-only summary above the standard, keyboard-accessible menu actions.
final class UsageSummaryView: NSView {
    init(provider: ProviderSnapshot?, refreshedAt: Date? = nil) {
        super.init(frame: NSRect(x: 0, y: 0, width: 320, height: 1))

        let content = NSStackView()
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        let name = provider?.id == .codex ? "Codex usage" : (provider?.name ?? "Codex usage")
        let heading = label(name, size: 15, weight: .semibold)
        let plan = label(provider?.planLabel.map { "\($0) plan" } ?? "", size: 11, color: .secondaryLabelColor)
        content.addArrangedSubview(row(heading, trailing: plan))

        if let provider {
            if let cachedAt = provider.cachedAt {
                content.addArrangedSubview(label(
                    "Last updated \(StatusFormatting.relative(cachedAt)) · Out of date",
                    size: 11, color: .systemOrange
                ))
            }

            for metric in provider.metrics {
                let section = NSStackView()
                section.orientation = .vertical
                section.alignment = .leading
                section.spacing = 5
                let title = metric.label.replacingOccurrences(of: "Codex · ", with: "", options: .anchored)
                section.addArrangedSubview(label(title, size: 12, weight: .medium, color: .secondaryLabelColor))

                if let remaining = metric.remainingPercent {
                    let color = Self.quotaColor(remaining, stale: provider.cachedAt != nil)
                    let amount = label("\(StatusFormatting.percent(remaining))%", size: 30, weight: .semibold, color: color)
                    amount.font = .monospacedDigitSystemFont(ofSize: 30, weight: .semibold)
                    let valueRow = NSStackView(views: [amount, label("remaining", size: 12, color: .secondaryLabelColor)])
                    valueRow.alignment = .firstBaseline
                    valueRow.spacing = 6
                    section.addArrangedSubview(valueRow)
                    let bar = QuotaBarView(remaining: remaining, color: color)
                    section.addArrangedSubview(bar)
                    bar.widthAnchor.constraint(equalTo: section.widthAnchor).isActive = true
                } else {
                    section.addArrangedSubview(label(metric.value, size: 20, weight: .semibold))
                }
                if let reset = metric.resetText {
                    let text = reset.prefix(1).uppercased() + reset.dropFirst()
                    section.addArrangedSubview(label(text, size: 11, color: .secondaryLabelColor))
                }
                content.addArrangedSubview(section)
                section.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
            }

            if provider.metrics.isEmpty {
                let title = provider.health == .unavailable ? "Usage unavailable" : "No usage limits available"
                content.addArrangedSubview(label(title, size: 20, weight: .semibold))
            }

            if let footer = provider.footer {
                if footer.hasPrefix("Credits balance: ") {
                    let value = String(footer.dropFirst("Credits balance: ".count))
                    content.addArrangedSubview(row(
                        label("Credits", size: 12, color: .secondaryLabelColor),
                        trailing: label(value, size: 12, weight: .medium)
                    ))
                } else {
                    content.addArrangedSubview(label(footer, size: 11, color: .secondaryLabelColor))
                }
            }

            let status: String
            if provider.health == .unavailable {
                status = "Couldn't refresh · Retrying automatically"
            } else if let refreshedAt {
                status = "Updated \(StatusFormatting.relative(refreshedAt)) · Every 5 min"
            } else {
                status = "Refreshes every 5 min"
            }
            content.addArrangedSubview(label(status, size: 11, color: .secondaryLabelColor))
        } else {
            content.addArrangedSubview(label("Checking your usage…", size: 13, color: .secondaryLabelColor))
        }

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 320),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            content.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])
        for view in content.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
        layoutSubtreeIfNeeded()
        frame.size.height = fittingSize.height
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }

    private func label(
        _ text: String,
        size: CGFloat,
        weight: NSFont.Weight = .regular,
        color: NSColor = .labelColor
    ) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString: text)
        field.font = .systemFont(ofSize: size, weight: weight)
        field.textColor = color
        field.setContentCompressionResistancePriority(.required, for: .vertical)
        field.setContentHuggingPriority(.required, for: .vertical)
        return field
    }

    private func row(_ leading: NSView, trailing: NSView) -> NSStackView {
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [leading, spacer, trailing])
        stack.alignment = .firstBaseline
        stack.spacing = 8
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        return stack
    }

    private static func quotaColor(_ remaining: Double, stale: Bool) -> NSColor {
        if remaining <= 10 { return .systemRed }
        if stale || remaining <= 20 { return .systemOrange }
        return .labelColor
    }
}

private final class QuotaBarView: NSView {
    private let remaining: Double
    private let color: NSColor

    init(remaining: Double, color: NSColor) {
        self.remaining = max(0, min(100, remaining))
        self.color = color
        super.init(frame: .zero)
        heightAnchor.constraint(equalToConstant: 6).isActive = true
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("Allowance remaining")
        setAccessibilityValue("\(StatusFormatting.percent(remaining)) percent")
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.labelColor.withAlphaComponent(0.1).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        let fill = NSRect(x: 0, y: 0, width: bounds.width * remaining / 100, height: bounds.height)
        (color == .labelColor ? NSColor.controlAccentColor : color).setFill()
        NSBezierPath(roundedRect: fill, xRadius: 3, yRadius: 3).fill()
    }
}
