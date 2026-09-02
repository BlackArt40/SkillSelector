import Foundation
import XCTest
@testable import SkillSelector

/// Regression tests for the translation source-language pin: the session
/// never auto-detects (a common stall path), so the source is recognized
/// from the description text up front — and a simplified-Chinese
/// description has nothing to translate at all.
final class DescriptionTranslationSourceTests: XCTestCase {
    func testEnglishDescriptionPinsEnglish() {
        XCTAssertEqual(
            DescriptionTranslationSource.preferredSource(
                in: "Review the changes since a fixed point along two axes."
            ),
            Locale.Language(identifier: "en")
        )
    }

    func testSimplifiedChineseDescriptionHasNothingToTranslate() {
        XCTAssertNil(
            DescriptionTranslationSource.preferredSource(
                in: "跨 Agent 管理本地 Skill 的只读信息看板，处理交给 Finder。"
            ),
            "简体中文描述已是目标语言，不显示翻译按钮"
        )
    }

    func testEmptyOrLanguagelessTextHasNothingToTranslate() {
        XCTAssertNil(DescriptionTranslationSource.preferredSource(in: "   \n\t "))
    }

    func testOtherLanguageIsPinnedAsIs() {
        XCTAssertEqual(
            DescriptionTranslationSource.preferredSource(
                in: "Verwende diesen Skill, um Aufgaben im Projekt zu planen und zu verfolgen."
            ),
            Locale.Language(identifier: "de"),
            "非英文描述按其自身语言固定源语言，而不是强行按英文翻译"
        )
    }

    func testTraditionalChineseStillTranslatesToSimplified() {
        let source = DescriptionTranslationSource.preferredSource(
            in: "這個技能用於在專案中規劃與追蹤任務的執行進度。"
        )
        XCTAssertEqual(source, Locale.Language(identifier: "zh-Hant"),
                       "繁体中文 → 简体中文是合法的语言对")
    }
}
