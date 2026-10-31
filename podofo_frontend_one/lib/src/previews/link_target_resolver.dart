import 'link_target.dart';

/// M1 deliberately accepts only explicit destination areas, without inference.
class LinkTargetResolver {
  const LinkTargetResolver();
  ResolvedLinkTarget resolve(
    PreviewDestination? destination, {
    Object? evidenceIdentity,
  }) {
    if (destination?.area case final area?) {
      return ResolvedLinkTarget(
        tier: LinkTargetTier.explicitArea,
        kind: LinkTargetKind.explicitArea,
        reason: 'explicitFitR',
        evidenceIdentity: evidenceIdentity,
        parts: [(page: destination!.page, bounds: area)],
      );
    }
    return ResolvedLinkTarget(
      tier: LinkTargetTier.unresolved,
      reason: destination == null
          ? 'invalidDestination'
          : 'identityMatchingDeferred',
      evidenceIdentity: evidenceIdentity,
    );
  }
}
