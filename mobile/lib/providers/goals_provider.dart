import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/models.dart';
import 'core_providers.dart';
import 'session_provider.dart';

class GoalsNotifier extends AsyncNotifier<List<SavingsGoal>> {
  @override
  Future<List<SavingsGoal>> build() async {
    final user = requireUser(ref);
    final goals = await ref.watch(apiServiceProvider).getGoals(user.id);
    // Active goals first, then completed ones.
    goals.sort((a, b) => (a.isCompleted ? 1 : 0).compareTo(b.isCompleted ? 1 : 0));
    return goals;
  }

  /// Throws [ApiException] so the form can show it.
  Future<void> create({required String name, required double target, DateTime? targetDate}) async {
    await ref.read(apiServiceProvider).createGoal(name: name, targetAmount: target, targetDate: targetDate);
    ref.invalidateSelf();
  }

  Future<void> edit(int goalId, Map<String, dynamic> changes) async {
    await ref.read(apiServiceProvider).updateGoal(goalId, changes);
    ref.invalidateSelf();
  }

  Future<void> contribute(int goalId, double amount) async {
    await ref.read(apiServiceProvider).contributeToGoal(goalId, amount);
    ref.invalidateSelf();
  }

  Future<void> delete(int goalId) async {
    await ref.read(apiServiceProvider).deleteGoal(goalId);
    ref.invalidateSelf();
  }
}

final goalsProvider = AsyncNotifierProvider<GoalsNotifier, List<SavingsGoal>>(GoalsNotifier.new);
