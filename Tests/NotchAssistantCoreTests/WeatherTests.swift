import FoundationModels
@testable import NotchAssistantCore
import Testing

struct WeatherTests {
    let tools = ToolRegistry(tools: ToolRegistry.standard.tools, isEnabled: { _ in true }).enabledTools()
    /// The live values from Open-Meteo for Amsterdam when this was written.
    let sample = OpenMeteo.Forecast(currentTemperature: 21.5, currentCode: 0, highs: [21.5, 19.4], lows: [11.4, 15.5], codes: [3, 3], rainChances: [0, 45])

    @Test func todayAnswer() {
        #expect(WeatherTool.answer(sample, place: "Amsterdam", tomorrow: false) == "It's 22° and clear in Amsterdam. High 22°, low 11°.")
    }

    @Test func tomorrowWithRain() {
        #expect(WeatherTool.answer(sample, place: "Amsterdam", tomorrow: true) == "Tomorrow in Amsterdam: overcast, high 19°, low 16°. 45% chance of rain.")
    }

    private func weather(_ transcript: String) -> WeatherArguments? {
        guard let step = DirectMatcher.plan(for: transcript, tools: tools)?.steps.first, step.tool.name == "getWeather" else { return nil }
        return try? WeatherArguments(step.arguments)
    }

    @Test(arguments: ["How's the weather?", "what's the weather like", "What's the temperature outside", "is it going to rain"])
    func questionsAreAnswered(transcript: String) {
        #expect(weather(transcript)?.day == "today")
    }

    @Test func placeAndDay() {
        let args = weather("what's the weather in Paris tomorrow")
        #expect(args?.place == "paris")
        #expect(args?.day == "tomorrow")
    }

    @Test func explicitSearchStaysASearch() {
        #expect(weather("search for the weather in Paris") == nil)
    }

    @Test func homeCityFromTimeZone() {
        #expect(!WeatherSettings.defaultCity.isEmpty)
        #expect(!WeatherSettings.defaultCity.contains("_"))
    }

    @Test func answersBecomeReplies() {
        let acting = AssistantState.acting(tool: ToolLabel(name: "getWeather", title: "Weather", symbol: "cloud.sun"), target: "")
        #expect(StateMachine.transition(from: acting, on: .answer("It's 20°")) == .reply("It's 20°"))
    }
}
