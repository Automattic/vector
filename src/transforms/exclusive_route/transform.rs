use vector_lib::transform::SyncTransform;

use crate::{
    conditions::Condition,
    config::TransformContext,
    event::Event,
    transforms::{
        TransformOutputsBuf,
        exclusive_route::config::{ExclusiveRouteConfig, UNMATCHED_ROUTE},
    },
};

#[derive(Clone)]
pub struct ResolvedRoute {
    name: String,
    condition: Condition,
}

#[derive(Clone)]
pub struct ExclusiveRoute {
    routes: Vec<ResolvedRoute>,
}

impl ExclusiveRoute {
    pub fn new(config: &ExclusiveRouteConfig, context: &TransformContext) -> crate::Result<Self> {
        let resolved_routes = config
            .routes
            .iter()
            .map(|route| {
                let condition = route
                    .condition
                    .build(&context.enrichment_tables, &context.metrics_storage)?;
                Ok(ResolvedRoute {
                    name: route.name.clone(),
                    condition,
                })
            })
            .collect::<crate::Result<Vec<_>>>()?;

        Ok(Self {
            routes: resolved_routes,
        })
    }
}

impl SyncTransform for ExclusiveRoute {
    fn transform(&mut self, mut event: Event, output: &mut TransformOutputsBuf) {
        // Conditions hand the event back unchanged, so no clone is needed per check.
        for route in &self.routes {
            let (result, checked) = route.condition.check(event);
            event = checked;
            if result {
                output.push(Some(&route.name), event);
                return;
            }
        }

        output.push(Some(UNMATCHED_ROUTE), event);
    }
}
