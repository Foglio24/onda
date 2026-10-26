import Foundation

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

let nominal = EnergyBudget(thermalState: .nominal, lowPowerMode: false)
check(nominal.allowsSpeculativeWork && nominal.allowsAudioConversion && nominal.allowsMotionEffects,
      "Normal conditions should keep requested quality and optional preparation available")
let fair = EnergyBudget(thermalState: .fair, lowPowerMode: false)
check(!fair.allowsSpeculativeWork && !fair.allowsMotionEffects,
      "Warm devices should stop prefetch and motion before stronger thermal throttling")
check(fair.allowsAudioConversion && fair.allowsKaraoke,
      "A requested current-song operation remains available while only slightly warm")
for state in [ProcessInfo.ThermalState.serious, .critical] {
    let budget = EnergyBudget(thermalState: state, lowPowerMode: false)
    check(!budget.allowsSpeculativeWork && !budget.allowsAudioConversion && !budget.allowsKaraoke
          && !budget.allowsMotionEffects, "Hot devices must shed optional CPU, GPU and network work")
}
for state in [ProcessInfo.ThermalState.nominal, .fair, .serious, .critical] {
    let budget = EnergyBudget(thermalState: state, lowPowerMode: true)
    check(!budget.allowsSpeculativeWork && !budget.allowsAudioConversion && !budget.allowsKaraoke
          && !budget.allowsMotionEffects, "Low Power Mode must take priority at every thermal level")
}
print("Energy checks passed: all thermal levels and Low Power Mode")
